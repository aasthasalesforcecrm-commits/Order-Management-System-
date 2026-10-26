/**
 * Data-transfer class returned by the ERP org to the Sales org.
 * unitPrice comes from ERP PricebookEntry.UnitPrice in the ERP Standard Price Book.
 * These properties are JSON transport fields, not extra Product2 fields.
 */
global class OMSERPProductPriceDTO {
    global String erpProductId;
    global String name;
    global String productCode;
    global String description;
    global String family;
    global Boolean isActive;
    global Decimal quantity;
    global Decimal minimumOrderQuantity;
    global Decimal unitPrice;
}