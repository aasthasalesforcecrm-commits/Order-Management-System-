public class OMSOrderPDFQueueable
    implements Queueable, Database.AllowsCallouts {
 
    private Id orderId;
 
    // Constructor
    public OMSOrderPDFQueueable(Id orderId) {
        this.orderId = orderId;
    }
 
    // Main execution method
    public void execute(QueueableContext context) {
 
        try {
 
            // STEP 1: Get the Order details
            Order orderRecord = [
                SELECT Id, OrderNumber, ERP_Transfer_Status__c
                FROM Order
                WHERE Id = :orderId
                LIMIT 1
            ];
 
            // Create the standard PDF title
            String fileTitle = 'Order_' + orderRecord.OrderNumber;
 
            // STEP 2: Check whether the PDF already exists
            List<ContentDocumentLink> existingPDFs = [
                SELECT Id, ContentDocumentId,
                       ContentDocument.Title,
                       ContentDocument.FileType
                FROM ContentDocumentLink
                WHERE LinkedEntityId = :orderId
                AND ContentDocument.Title = :fileTitle
                AND ContentDocument.FileType = 'PDF'
                LIMIT 1
            ];
 
            // STEP 3: If the Order was already transferred,
            // do not generate or transfer it again.
            if (orderRecord.ERP_Transfer_Status__c == 'Sent') {
 
                System.debug(
                    'Order already transferred successfully: ' + orderId
                );
 
                return;
            }
 
            // STEP 4: If the PDF already exists, reuse it
            if (!existingPDFs.isEmpty()) {
 
                System.debug(
                    'PDF already exists for Order: ' + orderId
                );
 
                System.debug(
                    'Existing PDF ContentDocumentId: ' +
                    existingPDFs[0].ContentDocumentId
                );
 
                // Do not generate another PDF.
                // Retry the ERP transfer using the existing file.
                System.enqueueJob(
                    new OMSOrderTransferQueueable(orderId, 0)
                );
 
                return;
            }
 
            // STEP 5: Generate the PDF because none exists
            PageReference pdfPage = Page.OMSOrderPDF;
 
            pdfPage.getParameters().put(
                'id',
                String.valueOf(orderId)
            );
 
            Blob pdfContent = pdfPage.getContentAsPDF();
 
            System.debug(
                'PDF generated successfully. Size: ' +
                pdfContent.size()
            );
 
            // STEP 6: Save the PDF as a Salesforce File
            ContentVersion fileRecord = new ContentVersion();
 
            fileRecord.Title = fileTitle;
            fileRecord.PathOnClient = fileTitle + '.pdf';
            fileRecord.VersionData = pdfContent;
 
            // Automatically link the file to the Order
            fileRecord.FirstPublishLocationId = orderId;
 
            insert fileRecord;
 
            System.debug(
                'PDF saved successfully for Order: ' + orderId
            );
 
            // STEP 7: Start the ERP transfer
            System.enqueueJob(
                new OMSOrderTransferQueueable(orderId, 0)
            );
 
            System.debug(
                'ERP transfer Queueable enqueued for Order: ' +
                orderId
            );
 
        } catch (Exception ex) {
 
            System.debug(
                LoggingLevel.ERROR,
                'PDF Queueable Error: ' + ex.getMessage()
            );
 
            // STEP 8: Log the error in the Sales org
            try {
 
                Integration_Log__c logRecord =
                    new Integration_Log__c();
 
                logRecord.Endpoint__c = 'Order PDF Generation';
                logRecord.Status__c = 'Failed';
                logRecord.Error_Message__c = ex.getMessage();
                logRecord.Timestamp__c = System.now();
 
                insert logRecord;
 
            } catch (Exception logException) {
 
                System.debug(
                    LoggingLevel.ERROR,
                    'Integration log creation failed: ' +
                    logException.getMessage()
                );
            }
 
            // STEP 9: Mark the Order as Failed
            try {
 
                Order failedOrder = new Order(
                    Id = orderId,
                    ERP_Transfer_Status__c = 'Failed'
                );
 
                update failedOrder;
 
            } catch (Exception statusException) {
 
                System.debug(
                    LoggingLevel.ERROR,
                    'Could not update Order transfer status: ' +
                    statusException.getMessage()
                );
            }
        }
    }
}