public with sharing class OMSCatalogueController {
    public class CatalogueColumn {
        @AuraEnabled public String fieldName { get; set; }
        @AuraEnabled public String label { get; set; }
        @AuraEnabled public Boolean filterable { get; set; }
        @AuraEnabled public Boolean sortable { get; set; }
        @AuraEnabled public Integer displayOrder { get; set; }
    }

    public class ProductRow {
        @AuraEnabled public Id id { get; set; }
        @AuraEnabled public String name { get; set; }
        @AuraEnabled public String productCode { get; set; }
        @AuraEnabled public String family { get; set; }
        @AuraEnabled public Decimal unitPrice { get; set; }
        @AuraEnabled public Decimal minimumQuantity { get; set; }
        @AuraEnabled public Decimal maximumQuantity { get; set; }
        @AuraEnabled public Map<String, Object> configuredValues { get; set; }
    }

    public class CatalogueResponse {
        @AuraEnabled public List<CatalogueColumn> columns { get; set; }
        @AuraEnabled public List<ProductRow> products { get; set; }
        @AuraEnabled public List<String> families { get; set; }
        @AuraEnabled public Integer totalRecords { get; set; }
        @AuraEnabled public Boolean familyFilterEnabled { get; set; }
    }

    @AuraEnabled(cacheable=true)
public static CatalogueResponse getCatalogue(
    String searchText,
    String familyFilter,
    String sortBy,
    Boolean sortAscending,
    Integer pageNumber,
    Integer pageSize
) {
    if (pageNumber == null || pageNumber < 1) {
        pageNumber = 1;
    }
 
    if (pageSize == null || pageSize < 1 || pageSize > 100) {
        pageSize = 20;
    }
 
    CatalogueResponse response = new CatalogueResponse();
    response.columns = getConfiguredColumns();
    response.products = new List<ProductRow>();
    response.families = new List<String>();
    response.familyFilterEnabled = false;
 
    for (CatalogueColumn column : response.columns) {
        if (column.fieldName == 'Family') {
            response.familyFilterEnabled = column.filterable;
        }
    }
 
    Set<String> selectedFields = new Set<String>{
        'Id', 'Name', 'IsActive', 'ProductCode', 'Family'
    };
 
    addFieldIfAvailable(selectedFields, 'Quantity__c');
    addFieldIfAvailable(selectedFields, 'Minimum_Order_Quantity__c');
 
    for (CatalogueColumn column : response.columns) {
        if (column.fieldName != 'UnitPrice') {
            selectedFields.add(column.fieldName);
        }
    }
 
    List<String> fields = new List<String>();
    fields.addAll(selectedFields);
    fields.sort();
 
    String queryText =
        'SELECT ' + String.join(fields, ',') +
        ' FROM Product2 WHERE IsActive = true';
 
    List<String> conditions = new List<String>();
    Map<String, Object> binds = new Map<String, Object>();
 
    if (String.isNotBlank(searchText)) {
        conditions.add(
            '(Name LIKE :searchPattern OR ProductCode LIKE :searchPattern)'
        );
        binds.put('searchPattern', '%' + searchText.trim() + '%');
    }
 
    if (response.familyFilterEnabled &&
        String.isNotBlank(familyFilter)) {
        conditions.add('Family = :familyFilter');
        binds.put('familyFilter', familyFilter);
    }
 
    if (!conditions.isEmpty()) {
        queryText += ' AND ' + String.join(conditions, ' AND ');
    }
 
    queryText += ' ORDER BY Name ASC LIMIT 5000';
 
    List<SObject> records = Database.queryWithBinds(
        queryText,
        binds,
        AccessLevel.USER_MODE
    );
 
    Set<Id> productIds = new Set<Id>();
    Set<String> familySet = new Set<String>();
 
    for (SObject record : records) {
        productIds.add((Id)record.get('Id'));
 
        String familyName = (String)record.get('Family');
 
        if (String.isNotBlank(familyName)) {
            familySet.add(familyName);
        }
    }
 
    response.families.addAll(familySet);
    response.families.sort();
 
    Map<Id, Decimal> prices = getLocalPrices(productIds);
 
    for (SObject record : records) {
        ProductRow row = new ProductRow();
 
        row.id = (Id)record.get('Id');
        row.name = (String)record.get('Name');
        row.productCode = (String)record.get('ProductCode');
        row.family = (String)record.get('Family');
 
        row.unitPrice = prices.get(row.id);
 
        if (selectedFields.contains('Minimum_Order_Quantity__c')) {
            row.minimumQuantity =
                (Decimal)record.get('Minimum_Order_Quantity__c');
        }
 
        if (row.minimumQuantity == null || row.minimumQuantity < 1) {
            row.minimumQuantity = 1;
        }
 
        if (selectedFields.contains('Quantity__c')) {
            row.maximumQuantity = (Decimal)record.get('Quantity__c');
        }
 
        row.configuredValues = new Map<String, Object>();
 
        for (CatalogueColumn column : response.columns) {
            if (column.fieldName == 'UnitPrice') {
                row.configuredValues.put('UnitPrice', row.unitPrice);
            } else {
                row.configuredValues.put(
                    column.fieldName,
                    record.get(column.fieldName)
                );
            }
        }
 
        response.products.add(row);
    }
 
    Boolean ascending = sortAscending == null || sortAscending;
 
    response.products.sort(
        new ProductSorter(sortBy, ascending)
    );
 
    response.totalRecords = response.products.size();
 
    Integer first = (pageNumber - 1) * pageSize;
    Integer last = Math.min(
        first + pageSize,
        response.products.size()
    );
 
    List<ProductRow> page = new List<ProductRow>();
 
    for (Integer i = first; i < last; i++) {
        page.add(response.products[i]);
    }
 
    response.products = page;
 
    return response;
}
 

    @AuraEnabled(cacheable=true)
    public static List<Account> getAccounts(String searchText) {
        String pattern = '%' + (String.isBlank(searchText) ? '' : searchText.trim()) + '%';
        return [SELECT Id, Name, ERP_Customer_ID__c FROM Account
            WHERE Name LIKE :pattern ORDER BY Name LIMIT 100];
    }

    private static List<CatalogueColumn> getConfiguredColumns() {
        List<CatalogueColumn> columns = new List<CatalogueColumn>();
        Map<String, Schema.SObjectField> metadataFields = Schema.SObjectType.Catalogue_Config__mdt.fields.getMap();

        for (Catalogue_Config__mdt config : Catalogue_Config__mdt.getAll().values()) {
            String fieldName = metadataText(config, metadataFields, 'Field_API_Name__c');
            if (!isSafeProductField(fieldName) || fieldName == 'Name') continue;

            Object visible = metadataValue(config, metadataFields, 'Show_In_Catalogue__c');
            if (visible != null && String.valueOf(visible).toLowerCase() == 'false') continue;

            CatalogueColumn column = new CatalogueColumn();
            column.fieldName = fieldName;
            column.label = metadataText(config, metadataFields, 'Display_Label__c');
            if (String.isBlank(column.label)) {
                column.label = Schema.SObjectType.Product2.fields.getMap().get(fieldName).getDescribe().getLabel();
            }
            column.filterable = String.valueOf(metadataValue(config, metadataFields, 'Is_Filterable__c')).toLowerCase() == 'true';
            column.sortable = String.valueOf(metadataValue(config, metadataFields, 'Is_Sortable__c')).toLowerCase() == 'true';
            column.displayOrder = 999;
            Object orderValue = metadataValue(config, metadataFields, 'Display_Order__c');
            if (orderValue != null) {
                try { column.displayOrder = Integer.valueOf(String.valueOf(orderValue)); }
                catch (Exception ignored) { column.displayOrder = 999; }
            }
            columns.add(column);
        }

        addRequiredColumn(columns, 'ProductCode', 1, false);
        addRequiredColumn(columns, 'Family', 2, true);
        columns.sort(new ColumnSorter());
        return columns;
    }

    private static void addRequiredColumn(List<CatalogueColumn> columns, String fieldName,
        Integer orderValue, Boolean filterable) {
        for (CatalogueColumn column : columns) if (column.fieldName == fieldName) return;
        CatalogueColumn column = new CatalogueColumn();
        column.fieldName = fieldName;
        column.label = Schema.SObjectType.Product2.fields.getMap().get(fieldName).getDescribe().getLabel();
        column.filterable = filterable;
        column.sortable = true;
        column.displayOrder = orderValue;
        columns.add(column);
    }

    private static Object metadataValue(SObject record, Map<String, Schema.SObjectField> fields, String name) {
        return fields.containsKey(name) ? record.get(name) : null;
    }

    private static String metadataText(SObject record, Map<String, Schema.SObjectField> fields, String name) {
        Object value = metadataValue(record, fields, name);
        return value == null ? null : String.valueOf(value);
    }

    private static void addFieldIfAvailable(Set<String> fields, String name) {
        if (Schema.SObjectType.Product2.fields.getMap().containsKey(name)) fields.add(name);
    }

    private static Boolean isSafeProductField(String name) {
        Map<String, Schema.SObjectField> fields = Schema.SObjectType.Product2.fields.getMap();
        return !String.isBlank(name) && fields.containsKey(name) &&
            fields.get(name).getDescribe().isAccessible();
    }

    private static Map<Id, Decimal> getLocalPrices(Set<Id> productIds) {
        Map<Id, Decimal> prices = new Map<Id, Decimal>();
        if (productIds.isEmpty()) return prices;

        Id standardBookId = Test.isRunningTest() ? Test.getStandardPricebookId() :
            [SELECT Id FROM Pricebook2 WHERE IsStandard = true LIMIT 1].Id;
        Id erpBookId;
        List<Pricebook2> erpBooks = [SELECT Id FROM Pricebook2 WHERE Name = 'ERP Price Book' AND IsActive = true LIMIT 1];
        if (!erpBooks.isEmpty()) erpBookId = erpBooks[0].Id;

        Set<Id> bookIds = new Set<Id>{standardBookId};
        if (erpBookId != null) bookIds.add(erpBookId);
        Map<Id, Decimal> standardPrices = new Map<Id, Decimal>();
        Map<Id, Decimal> erpPrices = new Map<Id, Decimal>();
        for (PricebookEntry entry : [SELECT Product2Id, Pricebook2Id, UnitPrice FROM PricebookEntry
            WHERE Pricebook2Id IN :bookIds AND Product2Id IN :productIds AND IsActive = true]) {
            if (entry.Pricebook2Id == erpBookId) erpPrices.put(entry.Product2Id, entry.UnitPrice);
            else standardPrices.put(entry.Product2Id, entry.UnitPrice);
        }
        for (Id productId : productIds) {
            if (erpPrices.containsKey(productId)) prices.put(productId, erpPrices.get(productId));
            else if (standardPrices.containsKey(productId)) prices.put(productId, standardPrices.get(productId));
        }
        return prices;
    }

    private class ColumnSorter implements Comparator<CatalogueColumn> {
        public Integer compare(CatalogueColumn a, CatalogueColumn b) {
            if (a.displayOrder == b.displayOrder) return a.fieldName.compareTo(b.fieldName);
            return a.displayOrder < b.displayOrder ? -1 : 1;
        }
    }

    private class ProductSorter implements Comparator<ProductRow> {
        private String sortBy;
        private Boolean ascending;
        ProductSorter(String sortBy, Boolean ascending) { this.sortBy = sortBy; this.ascending = ascending; }

        public Integer compare(ProductRow a, ProductRow b) {
            Integer result;
            if (sortBy == 'price') {
                if (a.unitPrice == null && b.unitPrice == null) result = 0;
                else if (a.unitPrice == null) result = 1;
                else if (b.unitPrice == null) result = -1;
                else if (a.unitPrice == b.unitPrice) result = 0;
                else result = a.unitPrice < b.unitPrice ? -1 : 1;
            } else {
                result = (a.name == null ? '' : a.name.toLowerCase()).compareTo(
                    b.name == null ? '' : b.name.toLowerCase());
            }
            return ascending ? result : -result;
        }
    }
}