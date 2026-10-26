public with sharing class OMSProductSyncService {

    public class SyncResult {
        public Integer recordsProcessed = 0;
        public Integer recordsFailed = 0;
        public List<String> errors = new List<String>();
    }

    public static List<ProductDTO> fetchChangedProducts(Datetime lastSuccess) {
        if (lastSuccess == null) {
            throw new CalloutException('Last sync time is missing.');
        }

        Long sinceMillis = lastSuccess.getTime();
        Long untilMillis = Datetime.now().getTime();

        HttpRequest req = new HttpRequest();
        req.setEndpoint(
            'callout:ERP/services/apexrest/oms/v1/products' +
            '?sinceMs=' + String.valueOf(sinceMillis) +
            '&untilMs=' + String.valueOf(untilMillis)
        );
        req.setMethod('GET');
        req.setTimeout(120000);
        req.setHeader('Accept', 'application/json');

        HttpResponse res = new Http().send(req);

        if (res.getStatusCode() != 200) {
            throw new CalloutException(
                'ERP product API failed. HTTP ' +
                res.getStatusCode() + ': ' + res.getBody()
            );
        }

        ProductResponse response =
            (ProductResponse) JSON.deserialize(
                res.getBody(), ProductResponse.class
            );

        if (response == null || response.products == null) {
            throw new CalloutException(
                'Invalid ERP response: products list is missing.'
            );
        }

        return response.products;
    }

    public static SyncResult syncProducts(List<ProductDTO> incoming) {
        SyncResult result = new SyncResult();

        if (incoming == null || incoming.isEmpty()) {
            return result;
        }

        Map<String, ProductDTO> dtoByErpId =
            new Map<String, ProductDTO>();
        List<ProductDTO> validDtos = new List<ProductDTO>();
        List<Product2> productsToUpsert = new List<Product2>();
        Set<String> requestedBookNames = new Set<String>();
        Set<String> failedErpIds = new Set<String>();

        for (ProductDTO dto : incoming) {
            if (dto == null) {
                result.errors.add('Product data is missing.');
                continue;
            }

            if (String.isBlank(dto.erpProductId)) {
                result.errors.add('ERP Product ID is missing.');
                continue;
            }

            if (dtoByErpId.containsKey(dto.erpProductId)) {
                failedErpIds.add(dto.erpProductId);
                result.errors.add(
                    'Duplicate ERP Product ID: ' + dto.erpProductId
                );
                continue;
            }

            dtoByErpId.put(dto.erpProductId, dto);

            String validationError = validateProduct(dto);

            if (validationError != null) {
                failedErpIds.add(dto.erpProductId);
                result.errors.add(validationError);
                continue;
            }

            validDtos.add(dto);

            productsToUpsert.add(new Product2(
                ERP_Product_ID__c = dto.erpProductId,
                Name = dto.name,
                ProductCode = dto.productCode,
                Family = dto.family,
                IsActive = dto.isActive,
                Minimum_Order_Quantity__c = dto.minimumOrderQuantity,
                Quantity__c = dto.availableQuantity
            ));

            for (PriceDTO price : dto.prices) {
                if (!price.pricebookIsStandard) {
                    requestedBookNames.add(price.pricebookName);
                }
            }
        }

        if (productsToUpsert.isEmpty()) {
            result.recordsFailed = incoming.size();
            return result;
        }

        Id standardBookId;
        Map<String, Id> bookIdByName = new Map<String, Id>();

        for (Pricebook2 pb : [
            SELECT Id, Name, IsStandard
            FROM Pricebook2
            WHERE IsStandard = true OR Name IN :requestedBookNames
        ]) {
            if (pb.IsStandard) {
                standardBookId = pb.Id;
            } else {
                bookIdByName.put(pb.Name, pb.Id);
            }
        }

        if (standardBookId == null) {
            result.errors.add('Standard Price Book was not found.');
            result.recordsFailed = incoming.size();
            return result;
        }

        List<Product2> finalProducts = new List<Product2>();
        List<ProductDTO> finalDtos = new List<ProductDTO>();

        for (Integer i = 0; i < validDtos.size(); i++) {
            ProductDTO dto = validDtos[i];
            Boolean validPrices = true;

            for (PriceDTO price : dto.prices) {
                if (!price.pricebookIsStandard &&
                    !bookIdByName.containsKey(price.pricebookName)) {
                    validPrices = false;
                    result.errors.add(
                        'Pricebook not found: ' + price.pricebookName +
                        ' for ERP Product ID ' + dto.erpProductId
                    );
                    break;
                }
            }

            if (validPrices) {
                finalProducts.add(productsToUpsert[i]);
                finalDtos.add(dto);
            } else {
                failedErpIds.add(dto.erpProductId);
            }
        }

        if (finalProducts.isEmpty()) {
            result.recordsFailed = incoming.size();
            return result;
        }

        Database.UpsertResult[] upsertResults = Database.upsert(
            finalProducts,
            Product2.ERP_Product_ID__c,
            false
        );

        List<ProductDTO> successfulDtos = new List<ProductDTO>();
        Set<String> successfulErpIds = new Set<String>();

        for (Integer i = 0; i < upsertResults.size(); i++) {
            if (upsertResults[i].isSuccess()) {
                successfulDtos.add(finalDtos[i]);
                successfulErpIds.add(finalDtos[i].erpProductId);
            } else {
                failedErpIds.add(finalDtos[i].erpProductId);

                for (Database.Error err : upsertResults[i].getErrors()) {
                    result.errors.add(
                        'Product ' + finalDtos[i].erpProductId +
                        ': ' + err.getMessage()
                    );
                }
            }
        }

        if (successfulDtos.isEmpty()) {
            result.recordsFailed = incoming.size();
            return result;
        }

        Map<String, Id> productIdByErpId = new Map<String, Id>();

        for (Product2 p : [
            SELECT Id, ERP_Product_ID__c
            FROM Product2
            WHERE ERP_Product_ID__c IN :successfulErpIds
        ]) {
            productIdByErpId.put(p.ERP_Product_ID__c, p.Id);
        }

        Map<String, PricebookEntry> desiredEntries =
            new Map<String, PricebookEntry>();
        Map<String, String> erpIdByEntryKey =
            new Map<String, String>();

        Set<Id> productIds = new Set<Id>();
        Set<Id> bookIds = new Set<Id>{standardBookId};
        bookIds.addAll(bookIdByName.values());

        for (ProductDTO dto : successfulDtos) {
            Id productId = productIdByErpId.get(dto.erpProductId);

            if (productId == null) {
                failedErpIds.add(dto.erpProductId);
                result.errors.add(
                    'Could not retrieve product for ERP ID ' +
                    dto.erpProductId
                );
                continue;
            }

            productIds.add(productId);

            for (PriceDTO price : dto.prices) {
                Id bookId = price.pricebookIsStandard
                    ? standardBookId
                    : bookIdByName.get(price.pricebookName);

                String key = String.valueOf(productId) + ':' +
                    String.valueOf(bookId);

                desiredEntries.put(key, new PricebookEntry(
                    Product2Id = productId,
                    Pricebook2Id = bookId,
                    UnitPrice = price.unitPrice,
                    IsActive = price.isActive
                ));

                erpIdByEntryKey.put(key, dto.erpProductId);
            }
        }

        Map<String, PricebookEntry> existingEntries =
            new Map<String, PricebookEntry>();

        if (!productIds.isEmpty()) {
            for (PricebookEntry entry : [
                SELECT Id, Product2Id, Pricebook2Id
                FROM PricebookEntry
                WHERE Product2Id IN :productIds
                AND Pricebook2Id IN :bookIds
            ]) {
                String key = String.valueOf(entry.Product2Id) + ':' +
                    String.valueOf(entry.Pricebook2Id);

                existingEntries.put(key, entry);
            }
        }

        List<PricebookEntry> standardInsert = new List<PricebookEntry>();
        List<PricebookEntry> standardUpdate = new List<PricebookEntry>();
        List<PricebookEntry> customInsert = new List<PricebookEntry>();
        List<PricebookEntry> customUpdate = new List<PricebookEntry>();

        List<String> standardInsertKeys = new List<String>();
        List<String> standardUpdateKeys = new List<String>();
        List<String> customInsertKeys = new List<String>();
        List<String> customUpdateKeys = new List<String>();

        for (String key : desiredEntries.keySet()) {
            PricebookEntry entry = desiredEntries.get(key);
            PricebookEntry oldEntry = existingEntries.get(key);
            Boolean isStandard = entry.Pricebook2Id == standardBookId;

            if (oldEntry == null) {
                if (isStandard) {
                    standardInsert.add(entry);
                    standardInsertKeys.add(key);
                } else {
                    customInsert.add(entry);
                    customInsertKeys.add(key);
                }
            } else {
                entry.Id = oldEntry.Id;

                if (isStandard) {
                    standardUpdate.add(entry);
                    standardUpdateKeys.add(key);
                } else {
                    customUpdate.add(entry);
                    customUpdateKeys.add(key);
                }
            }
        }

        saveEntries(
            standardInsert, standardInsertKeys, false,
            erpIdByEntryKey, failedErpIds, result
        );

        saveEntries(
            standardUpdate, standardUpdateKeys, true,
            erpIdByEntryKey, failedErpIds, result
        );

        saveEntries(
            customInsert, customInsertKeys, false,
            erpIdByEntryKey, failedErpIds, result
        );

        saveEntries(
            customUpdate, customUpdateKeys, true,
            erpIdByEntryKey, failedErpIds, result
        );

        for (String erpId : successfulErpIds) {
            if (!failedErpIds.contains(erpId)) {
                result.recordsProcessed++;
            }
        }

        result.recordsFailed = incoming.size() - result.recordsProcessed;

        return result;
    }

    private static String validateProduct(ProductDTO dto) {
        if (String.isBlank(dto.name)) {
            return 'Product name is missing for ' + dto.erpProductId;
        }

        if (dto.isActive == null) {
            return 'Product active status is missing for ' +
                dto.erpProductId;
        }

        if (dto.minimumOrderQuantity == null ||
            dto.minimumOrderQuantity < 0) {
            return 'Minimum Order Quantity is missing or invalid for ' +
                dto.erpProductId;
        }

        if (dto.availableQuantity != null &&
            dto.availableQuantity < 0) {
            return 'Available Quantity is invalid for ' + dto.erpProductId;
        }

        if (dto.prices == null || dto.prices.isEmpty()) {
            return 'Price list is missing for ' + dto.erpProductId;
        }

        Boolean hasStandardPrice = false;

        for (PriceDTO price : dto.prices) {
            if (price == null ||
                String.isBlank(price.pricebookName) ||
                price.unitPrice == null ||
                price.unitPrice < 0 ||
                price.isActive == null ||
                price.pricebookIsStandard == null) {
                return 'Invalid price data for ' + dto.erpProductId;
            }

            if (price.pricebookIsStandard) {
                hasStandardPrice = true;
            }
        }

        if (!hasStandardPrice) {
            return 'Standard Price Book price is missing for ' +
                dto.erpProductId;
        }

        return null;
    }

    private static void saveEntries(
        List<PricebookEntry> entries,
        List<String> keys,
        Boolean isUpdate,
        Map<String, String> erpIdByEntryKey,
        Set<String> failedErpIds,
        SyncResult result
    ) {
        if (entries.isEmpty()) {
            return;
        }

        Database.SaveResult[] saveResults;

        if (isUpdate) {
            saveResults = Database.update(entries, false);
        } else {
            saveResults = Database.insert(entries, false);
        }

        for (Integer i = 0; i < saveResults.size(); i++) {
            if (!saveResults[i].isSuccess()) {
                String erpId = erpIdByEntryKey.get(keys[i]);
                failedErpIds.add(erpId);

                for (Database.Error err : saveResults[i].getErrors()) {
                    result.errors.add(
                        'Price entry failed for ERP ID ' + erpId +
                        ': ' + err.getMessage()
                    );
                }
            }
        }
    }

    // Top-level / Sibling DTO Classes to avoid multi-level inner class restriction
    public class ProductResponse {
        public List<ProductDTO> products;
    }

    public class ProductDTO {
        public String erpProductId;
        public String name;
        public String productCode;
        public String family;
        public Boolean isActive;
        public Decimal minimumOrderQuantity;
        public Decimal availableQuantity;
        public List<PriceDTO> prices;
    }

    public class PriceDTO {
        public String pricebookName;
        public Decimal unitPrice;
        public Boolean isActive;
        public Boolean pricebookIsStandard;
    }
}