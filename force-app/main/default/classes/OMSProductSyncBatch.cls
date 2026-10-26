public class OMSProductSyncBatch
    implements Database.Batchable<OMSERPProductPriceDTO>,
               Database.AllowsCallouts,
               Database.Stateful {

    private Datetime startTime = System.now();
    private Integer totalRecordsReceived = 0;
    private Integer recordsProcessed = 0;
    private Boolean calloutFailed = false;
    private String errorDetails = '';

    public Iterable<OMSERPProductPriceDTO> start(Database.BatchableContext bc) {
        HttpRequest request = new HttpRequest();
        request.setEndpoint('callout:ERP/services/apexrest/oms/products' + buildSinceParameter());
        request.setMethod('GET');
        request.setTimeout(10000);// wait for 10sec for erp response 

        try {
            HttpResponse response = new Http().send(request);
            if (response.getStatusCode() != 200) {
                calloutFailed = true;
                addError('ERP endpoint returned HTTP ' + response.getStatusCode() +
                    '. Response: ' + response.getBody());
                return new List<OMSERPProductPriceDTO>();
            }
            List<OMSERPProductPriceDTO> result =
                (List<OMSERPProductPriceDTO>) JSON.deserialize(
                    response.getBody(), List<OMSERPProductPriceDTO>.class);
            return result == null ? new List<OMSERPProductPriceDTO>() : result;
        } catch (Exception e) {
            calloutFailed = true;
            addError('ERP callout/response failed: ' + e.getMessage());
            return new List<OMSERPProductPriceDTO>();
        }
    }

    private String buildSinceParameter() {
        // Advance the watermark only after a completely successful sync.
        // If any record failed, retry the changes since the previous full success.
        List<Sync_Log__c> successfulLogs = [
            SELECT Start_Time__c
            FROM Sync_Log__c
            WHERE Records_Failed__c = 0 AND Start_Time__c != null
            ORDER BY Start_Time__c DESC
            LIMIT 1
        ];
        if (successfulLogs.isEmpty()) {
            return '';
        }
        return '?modifiedSinceMillis=' +
            EncodingUtil.urlEncode(String.valueOf(successfulLogs[0].Start_Time__c.getTime()), 'UTF-8');
    }

    public void execute(Database.BatchableContext bc, List<OMSERPProductPriceDTO> scope) {
        totalRecordsReceived += scope.size();

        List<OMSERPProductPriceDTO> validItems = new List<OMSERPProductPriceDTO>();
        List<Product2> productsToSave = new List<Product2>();
        for (OMSERPProductPriceDTO item : scope) {
            String validationMessage = validateItem(item);
            if (validationMessage != null) {
                addError(validationMessage);
                continue;
            }
            Product2 p = new Product2();
            p.ERP_Product_ID__c = item.erpProductId;
            p.Name = item.name;
            p.ProductCode = item.productCode;
            p.Description = item.description;
            p.Family = item.family;
            p.IsActive = item.isActive;
            p.Quantity__c = item.quantity;
            p.Minimum_Order_Quantity__c = item.minimumOrderQuantity;
            productsToSave.add(p);
            validItems.add(item);
        }
        //if (productsToSave.isEmpty()) return;

        Pricebook2 standardBook;
        Pricebook2 erpBook;
        try {
            standardBook = [SELECT Id, IsActive FROM Pricebook2 WHERE IsStandard = true LIMIT 1];
            if (!standardBook.IsActive) {
                standardBook.IsActive = true;
                update standardBook;
            }
            List<Pricebook2> books = [
    SELECT Id, Name, IsActive
    FROM Pricebook2
    WHERE Name = 'ERP Price Book'
    LIMIT 1
];
 
if (books.isEmpty()) {
    erpBook = new Pricebook2(
        Name = 'ERP Price Book',
        IsActive = true
    );
 
    Database.SaveResult result = Database.insert(erpBook, false);
 
    if (result.isSuccess()) {
        erpBook.Id = result.getId();
 
        addError(
            'DEBUG: ERP Price Book created successfully. ID: ' +
            erpBook.Id
        );
    } else {
        for (Database.Error err : result.getErrors()) {
            addError(
                'ERP Price Book creation failed. Status: ' +
                err.getStatusCode() +
                '. Message: ' + err.getMessage()
            );
        }
 
        return;
    }
} else {
    erpBook = books[0];
 
    addError(
        'DEBUG: ERP Price Book already exists. ID: ' +
        erpBook.Id
    );
 
    if (!erpBook.IsActive) {
        erpBook.IsActive = true;
        update erpBook;
    }
}           if (productsToSave.isEmpty()) return;
        } catch (Exception e) {
            addError('Could not prepare Sales price books: ' + e.getMessage());
            return;
        }

        // Deactivate existing entries before deactivating the Product2 record.
        Set<String> inactiveExternalIds = new Set<String>();
        for (OMSERPProductPriceDTO item : validItems) {
            if (!item.isActive) inactiveExternalIds.add(item.erpProductId);
        }
        Map<String, Id> existingIdByExternalId = new Map<String, Id>();
        if (!inactiveExternalIds.isEmpty()) {        
            for (Product2 existingProduct : [
                SELECT Id, ERP_Product_ID__c FROM Product2
                WHERE ERP_Product_ID__c IN :inactiveExternalIds
            ]) {
                existingIdByExternalId.put(existingProduct.ERP_Product_ID__c, existingProduct.Id);
            }
        }
        Set<Id> oldInactiveIds = new Set<Id>();
        oldInactiveIds.addAll(existingIdByExternalId.values());
        Set<Id> deactivationFailures = deactivatePrices(standardBook.Id, oldInactiveIds);
        deactivationFailures.addAll(deactivatePrices(erpBook.Id, oldInactiveIds));

        // Partial upsert keyed by ERP_Product_ID__c prevents duplicate products.
        Database.UpsertResult[] upsertResults = Database.upsert(
            productsToSave, Product2.Fields.ERP_Product_ID__c, false);

        Map<Id, OMSERPProductPriceDTO> savedItemsBySalesId = new Map<Id, OMSERPProductPriceDTO>();
        Set<Id> failedInactiveProductIds = new Set<Id>();
        for (Integer i = 0; i < upsertResults.size(); i++) {
            if (upsertResults[i].isSuccess()) {
                Id salesId = upsertResults[i].getId();
                savedItemsBySalesId.put(salesId, validItems[i]);
                if (!validItems[i].isActive && deactivationFailures.contains(salesId)) {
                    failedInactiveProductIds.add(salesId);
                }
            } else {
                for (Database.Error err : upsertResults[i].getErrors()) {
                    addError('Product ' + validItems[i].erpProductId +
                        ' upsert failed: ' + err.getMessage());
                }
            }
        }
        if (savedItemsBySalesId.isEmpty()) return;

        Map<Id, Decimal> standardPrices = new Map<Id, Decimal>();
        Set<Id> inactiveProductIds = new Set<Id>();
        for (Id salesId : savedItemsBySalesId.keySet()) {
            OMSERPProductPriceDTO item = savedItemsBySalesId.get(salesId);
            if (item.isActive) standardPrices.put(salesId, item.unitPrice);
            else inactiveProductIds.add(salesId);
        }

        // A custom PricebookEntry requires the product to have a Standard entry first.
        Set<Id> standardSuccess = syncPrices(standardBook.Id, standardPrices);
        Map<Id, Decimal> erpBookPrices = new Map<Id, Decimal>();
        for (Id productId : standardSuccess) {
            erpBookPrices.put(productId, standardPrices.get(productId));
        }
        Set<Id> erpBookSuccess = syncPrices(erpBook.Id, erpBookPrices);

        for (Id salesId : savedItemsBySalesId.keySet()) {
            OMSERPProductPriceDTO item = savedItemsBySalesId.get(salesId);
            if (item.isActive) {
                if (standardSuccess.contains(salesId) && erpBookSuccess.contains(salesId)) {
                    recordsProcessed++;
                }
            } else if (!failedInactiveProductIds.contains(salesId)) {
                recordsProcessed++;
            }
        }
    }

    private String validateItem(OMSERPProductPriceDTO item) {
        if (item == null) return 'Product not processed : empty response item.';
        if (String.isBlank(item.erpProductId)) return 'Product not processed : ERP_Product_ID__c is missing.';
        if (String.isBlank(item.name)) return 'Product ' + item.erpProductId + ' not processed : Name is missing.';
        if (item.isActive == null) return 'Product ' + item.erpProductId + ' not processed : IsActive is missing.';
        // Inactive products still need to be transferred so Sales can deactivate them.
        if (item.isActive && (item.quantity == null || item.quantity <= 0)) {
            return 'Product ' + item.erpProductId +
                ' not processed : maximum order quantity (Quantity__c) is missing or invalid.';
        }
        if (item.isActive && (item.unitPrice == null || item.unitPrice < 0)) {
            return 'Product ' + item.erpProductId +
                ' not processed : ERP Standard Price Book UnitPrice is missing or invalid.';
        }
        return null;
    }

    /** Creates or updates entries using partial DML and returns successful Product2 IDs. */
    private Set<Id> syncPrices(Id pricebookId, Map<Id, Decimal> priceByProduct) {
        Set<Id> successfulIds = new Set<Id>();
        if (priceByProduct.isEmpty()) return successfulIds;

        Map<Id, Id> entryIdByProductId = new Map<Id, Id>();
        for (PricebookEntry entry : [
            SELECT Id, Product2Id FROM PricebookEntry
            WHERE Pricebook2Id = :pricebookId AND Product2Id IN :priceByProduct.keySet()
        ]) {
            entryIdByProductId.put(entry.Product2Id, entry.Id);
        }

        List<PricebookEntry> inserts = new List<PricebookEntry>();
        List<Id> insertProductIds = new List<Id>();
        List<PricebookEntry> updates = new List<PricebookEntry>();
        List<Id> updateProductIds = new List<Id>();
        for (Id productId : priceByProduct.keySet()) {
            if (entryIdByProductId.containsKey(productId)) {
                // Update only fields required; do not include Product2Id on update.
                updates.add(new PricebookEntry(
                    Id = entryIdByProductId.get(productId),
                    UnitPrice = priceByProduct.get(productId),
                    IsActive = true
                ));
                updateProductIds.add(productId);
            } else {
                inserts.add(new PricebookEntry(
                    Pricebook2Id = pricebookId,
                    Product2Id = productId,
                    UnitPrice = priceByProduct.get(productId),
                    IsActive = true
                ));
                insertProductIds.add(productId);
            }
        }
        if (!inserts.isEmpty()) {
            Database.SaveResult[] results = Database.insert(inserts, false);
            for (Integer i = 0; i < results.size(); i++) {
                if (results[i].isSuccess()) successfulIds.add(insertProductIds[i]);
                else for (Database.Error err : results[i].getErrors()) {
                    addError('Price insert failed for Sales product ' + insertProductIds[i] +
                        ' in price book ' + pricebookId + ': ' + err.getMessage());
                }
            }
        }
        if (!updates.isEmpty()) {
            Database.SaveResult[] results = Database.update(updates, false);
            for (Integer i = 0; i < results.size(); i++) {
                if (results[i].isSuccess()) successfulIds.add(updateProductIds[i]);
                else for (Database.Error err : results[i].getErrors()) {
                    addError('Price update failed for Sales product ' + updateProductIds[i] +
                        ' in price book ' + pricebookId + ': ' + err.getMessage());
                }
            }
        }
        return successfulIds;
    }

    /** Deactivates entries first; returns product IDs whose entry deactivation failed. */
    private Set<Id> deactivatePrices(Id pricebookId, Set<Id> productIds) {
        Set<Id> failedProductIds = new Set<Id>();
        if (productIds.isEmpty()) return failedProductIds;
        List<PricebookEntry> entries = [
            SELECT Id, Product2Id FROM PricebookEntry
            WHERE Pricebook2Id = :pricebookId AND Product2Id IN :productIds AND IsActive = true
        ];
        List<PricebookEntry> updates = new List<PricebookEntry>();
        for (PricebookEntry entry : entries) {
            updates.add(new PricebookEntry(Id = entry.Id, IsActive = false));
        }
        if (!updates.isEmpty()) {
            Database.SaveResult[] results = Database.update(updates, false);
            for (Integer i = 0; i < results.size(); i++) {
                if (!results[i].isSuccess()) {
                    failedProductIds.add(entries[i].Product2Id);
                    for (Database.Error err : results[i].getErrors()) {
                        addError('Price deactivation failed for Sales product ' +
                            entries[i].Product2Id + ': ' + err.getMessage());
                    }
                }
            }
        }
        return failedProductIds;
    }

    private void addError(String message) {
        if (errorDetails == null) errorDetails = '';
        if (errorDetails.length() < 28000) errorDetails += message + '\n';
    }

    public void finish(Database.BatchableContext bc) {
        Integer failedCount = totalRecordsReceived - recordsProcessed;
        if (failedCount < 0) failedCount = 0;
        // A failed callout is recorded as one failed integration attempt even when
        // the ERP response contained no product rows to count.
        if (calloutFailed && failedCount == 0) failedCount = 1;

        try {
            insert new Sync_Log__c(
                Start_Time__c = startTime,
                End_Time__c = System.now(),
                Records_Processed__c = recordsProcessed,
                Records_Failed__c = failedCount,
                Error_Details__c = errorDetails,
                Sync_Type__c = 'Product Sync'
            );
        } catch (Exception e) {
            System.debug( 'Could not save Sync_Log__c: ' + e.getMessage());
        }

        if (failedCount > 0 || calloutFailed || !String.isBlank(errorDetails)) {
            sendFailureNotification(failedCount);
        }

        try {
            System.scheduleBatch(new OMSProductSyncBatch(),
                'OMS Product Sync ' + System.now().getTime(), 15, 500);
        } catch (Exception e) {
            System.debug( 'Could not schedule next product sync: ' + e.getMessage());
        }
    }

    private void sendFailureNotification(Integer failedCount) {
        String adminEmail = Label.OMS_Integration_Admin_Email;
 
        if (String.isBlank(adminEmail)) {
            System.debug(
               
                'Integration Admin email is not configured.'
            );
            return;
        }
 
        Messaging.SingleEmailMessage email = new Messaging.SingleEmailMessage();
 
        email.setToAddresses(new String[] { adminEmail });
 
        email.setSubject('OMS Product Sync Failure Notification');
 
        email.setPlainTextBody(
            'The ERP-to-Sales product sync encountered failures.'
            + '\n\nRecords received: ' + totalRecordsReceived
            + '\nRecords processed: ' + recordsProcessed
            + '\nRecords failed: ' + failedCount
            + '\n\nError details:\n' + errorDetails
        );
 
        try {
            Messaging.sendEmail( new Messaging.SingleEmailMessage[] { email });
 
        } catch (Exception e) {
            System.debug('Could not notify Integration Admin: '+ e.getMessage()
            );
        }
    }
}