public with sharing class OMSOrderPDFController {
 
    public Order orderRecord { get; private set; }
 
    public List<OrderLineView> lines { get; private set; }
 
    public OMSOrderPDFController(
        ApexPages.StandardController controller
    ) {
        Id orderId = controller.getId();
 
        orderRecord = [
            SELECT Id,
                   OrderNumber,
                   EffectiveDate,
                   Status,
                   TotalAmount,
                   Account.Name,
                   Account.Phone,
                   Account.BillingStreet,
                   Account.BillingCity,
                   Account.BillingState,
                   Account.BillingPostalCode,
                   Account.BillingCountry,
                   Account.ERP_Customer_ID__c
            FROM Order
            WHERE Id = :orderId
            LIMIT 1
        ];
 
        List<OrderItem> orderItems = [
            SELECT Id,
                   Quantity,
                   UnitPrice,
                   TotalPrice,
                   Price_Source__c,
                   Fallback_Reason__c,
                   PricebookEntry.Product2.Name,
                   PricebookEntry.Product2.ProductCode
            FROM OrderItem
            WHERE OrderId = :orderId
            ORDER BY CreatedDate
        ];
 
        lines = new List<OrderLineView>();
 
        for (OrderItem item : orderItems) {
            lines.add(new OrderLineView(item));
        }
    }
 
    public class OrderLineView {
 
        public OrderItem item { get; private set; }
 
        public Boolean fallbackUsed { get; private set; }
 
        public OrderLineView(OrderItem orderItem) {
 
            item = orderItem;
 
            fallbackUsed =
                orderItem.Price_Source__c != null &&
                orderItem.Price_Source__c
                    .toLowerCase()
                    .contains('fallback');
        }
    }
}