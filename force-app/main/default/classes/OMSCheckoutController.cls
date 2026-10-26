public with sharing class OMSCheckoutController {
    public class PriceResult {
        @AuraEnabled public Id productId { get; set; }
        @AuraEnabled public Decimal unitPrice { get; set; }
        @AuraEnabled public String priceSource { get; set; }
        @AuraEnabled public String fallbackReason { get; set; }
    }

    public class UpdatedPrice {
        @AuraEnabled public Id productId { get; set; }
        @AuraEnabled public Decimal unitPrice { get; set; }
        @AuraEnabled public String priceSource { get; set; }
        @AuraEnabled public String fallbackReason { get; set; }
    }

    public class CheckoutResult {
        @AuraEnabled public Boolean priceChanged { get; set; }
        @AuraEnabled public List<UpdatedPrice> updatedPrices { get; set; }
        @AuraEnabled public Id orderId { get; set; }
        @AuraEnabled public String orderNumber { get; set; }
    }

    private class CartRequest {
        public String accountId;
        public List<CartItemRequest> items;
    }
    private class CartItemRequest {
        public String productId;
        public Integer quantity;
        public Decimal expectedUnitPrice;
        public Decimal overridePrice;
        public String overrideReason;
    }
    private class ErpLookup {
        public Decimal price;
        public String reason;
    }

    @AuraEnabled(cacheable=true)
    public static Boolean isPriceOverrideAllowed() {
        return FeatureManagement.checkPermission('OMS_Price_Override');
    }

    @AuraEnabled
    public static PriceResult checkPrice(Id productId) {
        if (productId == null) throw new AuraHandledException('Select a product first.');
        ErpLookup erp = getErpPrice(productId);
        PriceResult result = new PriceResult();
        result.productId = productId;
        if (erp.reason == null) {
            result.unitPrice = erp.price;
            result.priceSource = 'ERP';
            result.fallbackReason = '';
        } else {
            result.unitPrice = getLocalPrice(productId);
            result.priceSource = 'Local';
            result.fallbackReason = erp.reason;
        }
        return result;
    }

    @AuraEnabled
    public static CheckoutResult checkout(String requestJson) {
        if (String.isBlank(requestJson)) throw new AuraHandledException('Checkout request is empty.');
        CartRequest request;
        try { request = (CartRequest)JSON.deserialize(requestJson, CartRequest.class); }
        catch (Exception e) { throw new AuraHandledException('Checkout request is invalid.'); }
        if (request == null || String.isBlank(request.accountId)) throw new AuraHandledException('Select an Account.');
        if (request.items == null || request.items.isEmpty()) throw new AuraHandledException('The cart is empty.');

        Account accountRecord = [SELECT Id, Name FROM Account WHERE Id = :request.accountId LIMIT 1];
        Boolean canOverride = isPriceOverrideAllowed();
        Set<Id> productIds = new Set<Id>();
        for (CartItemRequest item : request.items) {
            if (item == null || String.isBlank(item.productId)) throw new AuraHandledException('A cart line is missing its product.');
            productIds.add((Id)item.productId);
        }

        Map<Id, Product2> products = new Map<Id, Product2>([
            SELECT Id, Name, ProductCode, IsActive, Quantity__c, Minimum_Order_Quantity__c
            FROM Product2 WHERE Id IN :productIds
        ]);
        Map<Id, PriceResult> prices = new Map<Id, PriceResult>();
        for (Id productId : productIds) prices.put(productId, checkPrice(productId));

        CheckoutResult result = new CheckoutResult();
        result.priceChanged = false;
        result.updatedPrices = new List<UpdatedPrice>();
        for (Id productId : productIds) {
            PriceResult current = prices.get(productId);
            Decimal expectedPrice;
            for (CartItemRequest item : request.items) {
                if (item.productId == String.valueOf(productId)) expectedPrice = item.expectedUnitPrice;
            }
            if (expectedPrice == null || current.unitPrice == null || expectedPrice != current.unitPrice) result.priceChanged = true;
            UpdatedPrice updated = new UpdatedPrice();
            updated.productId = productId;
            updated.unitPrice = current.unitPrice;
            updated.priceSource = current.priceSource;
            updated.fallbackReason = current.fallbackReason;
            result.updatedPrices.add(updated);
        }
        if (result.priceChanged) return result;

        for (CartItemRequest item : request.items) {
            Id productId = (Id)item.productId;
            Product2 product = products.get(productId);
            if (product == null || !product.IsActive) throw new AuraHandledException('A product is missing or inactive.');
            if (item.quantity == null || item.quantity < 1) throw new AuraHandledException('Quantity must be a positive whole number for ' + product.Name + '.');
            Decimal minimum = product.Minimum_Order_Quantity__c == null ? 1 : product.Minimum_Order_Quantity__c;
            if (item.quantity < minimum) throw new AuraHandledException('Minimum quantity for ' + product.Name + ' is ' + minimum + '.');
            if (product.Quantity__c != null && item.quantity > product.Quantity__c) throw new AuraHandledException('Maximum quantity for ' + product.Name + ' is ' + product.Quantity__c + '.');
            if (item.overridePrice != null && !canOverride) throw new AuraHandledException('Only Sales Managers can override prices.');
            if (item.overridePrice != null && String.isBlank(item.overrideReason)) throw new AuraHandledException('Enter an override reason for ' + product.Name + '.');
            if (item.overridePrice != null && item.overridePrice < 0) throw new AuraHandledException('Override price cannot be negative.');
            if (prices.get(productId).unitPrice == null) throw new AuraHandledException('No ERP or local price is available for ' + product.Name + '.');
        }

        Id erpPricebookId = getErpPricebookId();
        ensurePricebookEntries(productIds, erpPricebookId, prices);
        Map<Id, PricebookEntry> entries = new Map<Id, PricebookEntry>();
        for (PricebookEntry entry : [SELECT Id, Product2Id FROM PricebookEntry
            WHERE Pricebook2Id = :erpPricebookId AND Product2Id IN :productIds AND IsActive = true]) {
            entries.put(entry.Product2Id, entry);
        }

        Order newOrder = new Order(AccountId = accountRecord.Id, EffectiveDate = Date.today(),
            Status = 'Draft', Pricebook2Id = erpPricebookId);
        List<OrderItem> orderItems = new List<OrderItem>();
        List<String> fallbackDetails = new List<String>();

        for (CartItemRequest item : request.items) {
            Id productId = (Id)item.productId;
            Product2 product = products.get(productId);
            PriceResult price = prices.get(productId);
            Boolean overridden = item.overridePrice != null;
            Decimal finalPrice = overridden ? item.overridePrice : price.unitPrice;
            OrderItem orderItem = new OrderItem(
                PricebookEntryId = entries.get(productId).Id,
                Quantity = item.quantity,
                UnitPrice = finalPrice,
                Price_Source__c = overridden ? 'Override' : price.priceSource,
                Fallback_Reason__c = price.fallbackReason,
                Price_Override_Reason__c = overridden ? item.overrideReason.trim() : null
            );
            orderItems.add(orderItem);
            if (!overridden && price.priceSource == 'Local') {
                fallbackDetails.add(product.Name + ' (' + product.ProductCode + '), quantity ' + item.quantity +
                    ', local price ' + price.unitPrice + ', reason: ' + price.fallbackReason);
            }
        }

        // Any failed Order or OrderItem insert rolls back the whole transaction.
        insert newOrder;
        for (OrderItem item : orderItems) item.OrderId = newOrder.Id;
        insert orderItems;

        result.orderId = newOrder.Id;
        result.orderNumber = String.valueOf(newOrder.OrderNumber);
        System.enqueueJob(new OMSOrderPDFQueueable(newOrder.Id));
        if (!fallbackDetails.isEmpty()) sendFallbackEmail(result.orderNumber, accountRecord.Name, fallbackDetails);
        return result;
    }

    private static ErpLookup getErpPrice(Id productId) {
        ErpLookup result = new ErpLookup();
        Product2 product = [SELECT ERP_Product_ID__c FROM Product2 WHERE Id = :productId LIMIT 1];
        if (String.isBlank(product.ERP_Product_ID__c)) {
            result.reason = 'not found';
            return result;
        }

        try {
            HttpRequest request = new HttpRequest();
            request.setEndpoint('callout:ERP/services/apexrest/oms/products');
            request.setMethod('GET');
            request.setTimeout(10000);
            HttpResponse response = new Http().send(request);
            if (response.getStatusCode() < 200 || response.getStatusCode() >= 300) {
                result.reason = 'error';
                return result;
            }
            Object data = JSON.deserializeUntyped(response.getBody());
            if (!(data instanceof List<Object>)) {
                result.reason = 'error';
                return result;
            }
            for (Object value : (List<Object>)data) {
                Map<String, Object> row = (Map<String, Object>)value;
                if (String.valueOf(row.get('erpProductId')) != product.ERP_Product_ID__c) continue;
                if (row.get('unitPrice') == null) {
                    result.reason = 'no price';
                    return result;
                }
                Decimal price = Decimal.valueOf(String.valueOf(row.get('unitPrice')));
                if (price < 0) {
                    result.reason = 'no price';
                    return result;
                }
                result.price = price;
                return result;
            }
            result.reason = 'not found';
        } catch (Exception e) {
            result.reason = 'error';
        }
        return result;
    }

    private static Decimal getLocalPrice(Id productId) {
        Id standardBookId = Test.isRunningTest() ? Test.getStandardPricebookId() :
            [SELECT Id FROM Pricebook2 WHERE IsStandard = true LIMIT 1].Id;
        List<Pricebook2> books = [SELECT Id FROM Pricebook2 WHERE Name = 'ERP Price Book' AND IsActive = true LIMIT 1];
        Id erpBookId = books.isEmpty() ? null : books[0].Id;
        Set<Id> bookIds = new Set<Id>{standardBookId};
        if (erpBookId != null) bookIds.add(erpBookId);
        Decimal standardPrice;
        Decimal erpPrice;
        for (PricebookEntry entry : [SELECT Pricebook2Id, UnitPrice FROM PricebookEntry
            WHERE Pricebook2Id IN :bookIds AND Product2Id = :productId AND IsActive = true]) {
            if (entry.Pricebook2Id == erpBookId) erpPrice = entry.UnitPrice;
            else standardPrice = entry.UnitPrice;
        }
        return erpPrice != null ? erpPrice : standardPrice;
    }

    private static Id getErpPricebookId() {
        List<Pricebook2> books = [SELECT Id, IsActive FROM Pricebook2 WHERE Name = 'ERP Price Book' LIMIT 1];
        if (!books.isEmpty()) {
            if (!books[0].IsActive) update new Pricebook2(Id = books[0].Id, IsActive = true);
            return books[0].Id;
        }
        Pricebook2 newBook = new Pricebook2(Name = 'ERP Price Book', IsActive = true);
        insert newBook;
        return newBook.Id;
    }

    private static void ensurePricebookEntries(Set<Id> productIds, Id erpBookId, Map<Id, PriceResult> prices) {
        Id standardBookId = Test.isRunningTest() ? Test.getStandardPricebookId() :
            [SELECT Id FROM Pricebook2 WHERE IsStandard = true LIMIT 1].Id;
        Pricebook2 standardBook = [SELECT Id, IsActive FROM Pricebook2 WHERE Id = :standardBookId LIMIT 1];
        if (!standardBook.IsActive) update new Pricebook2(Id = standardBookId, IsActive = true);

        Map<Id, PricebookEntry> standardEntries = new Map<Id, PricebookEntry>();
        for (PricebookEntry entry : [SELECT Id, Product2Id, UnitPrice, IsActive FROM PricebookEntry
            WHERE Pricebook2Id = :standardBookId AND Product2Id IN :productIds]) standardEntries.put(entry.Product2Id, entry);
        List<PricebookEntry> addStandard = new List<PricebookEntry>();
        List<PricebookEntry> activateStandard = new List<PricebookEntry>();
        for (Id productId : productIds) {
            if (!standardEntries.containsKey(productId)) {
                addStandard.add(new PricebookEntry(Pricebook2Id = standardBookId, Product2Id = productId,
                    UnitPrice = prices.get(productId).unitPrice, IsActive = true));
            } else if (!standardEntries.get(productId).IsActive) {
                PricebookEntry entry = standardEntries.get(productId);
                entry.IsActive = true;
                activateStandard.add(entry);
            }
        }
        if (!activateStandard.isEmpty()) update activateStandard;
        if (!addStandard.isEmpty()) insert addStandard;
        for (PricebookEntry entry : [SELECT Id, Product2Id, UnitPrice FROM PricebookEntry
            WHERE Pricebook2Id = :standardBookId AND Product2Id IN :productIds]) standardEntries.put(entry.Product2Id, entry);

        Map<Id, PricebookEntry> erpEntries = new Map<Id, PricebookEntry>();
        for (PricebookEntry entry : [SELECT Id, Product2Id, IsActive FROM PricebookEntry
            WHERE Pricebook2Id = :erpBookId AND Product2Id IN :productIds]) erpEntries.put(entry.Product2Id, entry);
        List<PricebookEntry> addErp = new List<PricebookEntry>();
        List<PricebookEntry> activateErp = new List<PricebookEntry>();
        for (Id productId : productIds) {
            if (!erpEntries.containsKey(productId)) {
                addErp.add(new PricebookEntry(Pricebook2Id = erpBookId, Product2Id = productId,
                    UnitPrice = standardEntries.get(productId).UnitPrice, IsActive = true));
            } else if (!erpEntries.get(productId).IsActive) {
                PricebookEntry entry = erpEntries.get(productId);
                entry.IsActive = true;
                activateErp.add(entry);
            }
        }
        if (!activateErp.isEmpty()) update activateErp;
        if (!addErp.isEmpty()) insert addErp;
    }

    private static void sendFallbackEmail(String orderNumber, String accountName, List<String> lines) {
        String recipients = Label.OMS_Integration_Admin_Email;
        if (String.isBlank(recipients) || recipients == 'CHANGE_ME') return;
        try {
            Messaging.SingleEmailMessage email = new Messaging.SingleEmailMessage();
            List<String> addresses = new List<String>();
            for (String address : recipients.split('[;,]')) {
                if (String.isNotBlank(address)) addresses.add(address.trim());
            }
            if (addresses.isEmpty()) return;
            email.setToAddresses(addresses);
            email.setSubject('OMS order ' + orderNumber + ' used local fallback pricing');
            email.setPlainTextBody('Order: ' + orderNumber + '\nAccount: ' + accountName +
                '\n\nFallback-priced products:\n- ' + String.join(lines, '\n- '));
            Messaging.sendEmail(new Messaging.SingleEmailMessage[]{email}, false);
        } catch (Exception e) {
            System.debug('Fallback notification email failed: ' + e.getMessage());
        }
    }
}