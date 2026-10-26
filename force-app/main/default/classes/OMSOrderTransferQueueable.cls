public class OMSOrderTransferQueueable
    implements Queueable, Database.AllowsCallouts {
 
    private Id orderId;
    private Integer attemptNumber;
 
    // Constructor
    public OMSOrderTransferQueueable(
        Id orderId,
        Integer attemptNumber
    ) {
        this.orderId = orderId;
        this.attemptNumber = attemptNumber == null
            ? 0
            : attemptNumber;
    }
 
    // Main method
    public void execute(QueueableContext context) {
 
        Integer statusCode;
 
        try {
 
            // STEP 1: Get Order and ERP customer details
            Order orderRecord = [
                SELECT Id,
                       OrderNumber,
                       ERP_Transfer_Status__c,
                       AccountId,
                       Account.ERP_Customer_ID__c
                FROM Order
                WHERE Id = :orderId
                LIMIT 1
            ];
 
            // Stop if ERP customer ID is missing
            if (orderRecord.AccountId == null ||
                String.isBlank(
                    orderRecord.Account.ERP_Customer_ID__c
                )) {
 
                handleFailure(
                    'ERP Customer ID is missing.',
                    null
                );
 
                return;
            }
 
            // STEP 2: Find the PDF linked to this Order
            String expectedTitle =
                'Order_' + orderRecord.OrderNumber;
 
            List<ContentDocumentLink> fileLinks = [
                SELECT ContentDocumentId
                FROM ContentDocumentLink
                WHERE LinkedEntityId = :orderRecord.Id
            ];
 
            Set<Id> documentIds = new Set<Id>();
 
            for (ContentDocumentLink linkRecord : fileLinks) {
                documentIds.add(linkRecord.ContentDocumentId);
            }
 
            if (documentIds.isEmpty()) {
 
                handleFailure(
                    'No Salesforce File is linked to the Order.',
                    null
                );
 
                return;
            }
 
            // Find the latest version of the correct PDF
            List<ContentVersion> versions = [
                SELECT Id,
                       Title,
                       PathOnClient,
                       VersionData,
                       ContentDocumentId
                FROM ContentVersion
                WHERE ContentDocumentId IN :documentIds
                AND Title = :expectedTitle
                AND FileExtension = 'pdf'
                ORDER BY VersionNumber DESC
                LIMIT 1
            ];
 
            if (versions.isEmpty()) {
 
                handleFailure(
                    'Order PDF was not found. Expected title: '
                    + expectedTitle,
                    null
                );
 
                return;
            }
 
            ContentVersion pdfFile = versions[0];
 
            // STEP 3: Convert PDF into Base64
            String pdfBase64 =
                EncodingUtil.base64Encode(pdfFile.VersionData);
 
            // STEP 4: Prepare request data
            Map<String, Object> requestData =
                new Map<String, Object>();
 
            requestData.put(
                'erpCustomerId',
                orderRecord.Account.ERP_Customer_ID__c
            );
 
            requestData.put(
                'orderNumber',
                orderRecord.OrderNumber
            );
 
            requestData.put(
                'pdfTitle',
                pdfFile.Title
            );
 
            requestData.put(
                'pdfFileName',
                pdfFile.PathOnClient
            );
 
            requestData.put(
                'pdfBase64',
                pdfBase64
            );
 
            // STEP 5: Prepare HTTP request
            HttpRequest request = new HttpRequest();
 
            request.setEndpoint(
                'callout:ERP/services/apexrest/oms/orders'
            );
 
            request.setMethod('POST');
 
            request.setHeader(
                'Content-Type',
                'application/json'
            );
 
            request.setTimeout(120000);
 
            request.setBody(JSON.serialize(requestData));
 
            // STEP 6: Send request to ERP
            Http http = new Http();
 
            HttpResponse response = http.send(request);
 
            statusCode = response.getStatusCode();
 
            System.debug(
                'ERP HTTP Status: ' + statusCode
            );
 
            System.debug(
                'ERP Response Body: ' + response.getBody()
            );
 
            // STEP 7: Check HTTP status
            if (statusCode < 200 || statusCode >= 300) {
 
                handleFailure(
                    'ERP API returned HTTP '
                    + statusCode
                    + '. Response: '
                    + response.getBody(),
                    statusCode
                );
 
                return;
            }
 
            // STEP 8: Safely read the JSON response
            Map<String, Object> responseData =
                parseResponse(response.getBody());
 
            Object successValue = responseData.get('success');
 
            Boolean isSuccessful =
                successValue != null &&
                String.valueOf(successValue)
                    .equalsIgnoreCase('true');
 
            // STEP 9: Check whether ERP actually saved the PDF
            if (!isSuccessful) {
 
                String errorMessage =
                    responseData.containsKey('message')
                    ? String.valueOf(
                        responseData.get('message')
                    )
                    : 'ERP API did not confirm a successful transfer.';
 
                handleFailure(
                    errorMessage,
                    statusCode
                );
 
                return;
            }
 
            // STEP 10: Mark the Order as Sent
            Order orderToUpdate = new Order(
                Id = orderRecord.Id,
                ERP_Transfer_Status__c = 'Sent'
            );
 
            update orderToUpdate;
 
            // STEP 11: Create success log in Sales org
            logIntegration(
                'Success',
                statusCode,
                'Order PDF transferred successfully. '
                + 'Order Number: '
                + orderRecord.OrderNumber
                + '. ERP Response: '
                + response.getBody()
            );
 
        } catch (Exception ex) {
 
            System.debug(
                'Order Transfer Error: ' + ex.getMessage()
            );
 
            handleFailure(
                ex.getMessage(),
                statusCode
            );
        }
    }
 
    // Safely parses either a JSON object or a JSON-encoded string
    private static Map<String, Object> parseResponse(
        String responseBody
    ) {
 
        Map<String, Object> emptyResponse =
            new Map<String, Object>();
 
        if (String.isBlank(responseBody)) {
            return emptyResponse;
        }
 
        Object parsed = JSON.deserializeUntyped(responseBody);
 
        // Normal response: {"success":true,"message":"..."}
        if (parsed instanceof Map<String, Object>) {
 
            return (Map<String, Object>) parsed;
        }
 
        // Also handle a response that contains JSON as a string
        if (parsed instanceof String) {
 
            Object nestedParsed = JSON.deserializeUntyped(
                (String) parsed
            );
 
            if (nestedParsed instanceof Map<String, Object>) {
 
                return (Map<String, Object>) nestedParsed;
            }
        }
 
        return emptyResponse;
    }
 
    // Handles failure and retries once
    private void handleFailure(
        String errorMessage,
        Integer statusCode
    ) {
 
        System.debug(
            'Transfer failed. Attempt: '
            + attemptNumber
            + '. Error: '
            + errorMessage
        );
 
        // Log the failure in Sales org
        logIntegration(
            'Failed',
            statusCode,
            errorMessage
        );
 
        // Retry only once
        if (attemptNumber < 1) {
 
            System.enqueueJob(
                new OMSOrderTransferQueueable(
                    orderId,
                    attemptNumber + 1
                )
            );
 
        } else {
 
            // Both attempts failed
            Order failedOrder = new Order(
                Id = orderId,
                ERP_Transfer_Status__c = 'Failed'
            );
 
            update failedOrder;
        }
    }
 
    // Creates an Integration Log in Sales org
    private void logIntegration(
        String status,
        Integer statusCode,
        String message
    ) {
 
        try {
 
            Integration_Log__c logRecord =
                new Integration_Log__c();
 
            logRecord.Endpoint__c =
                '/services/apexrest/oms/orders';
 
            logRecord.Status__c = status;
 
            logRecord.Error_Message__c =
                'HTTP Status: '
                + String.valueOf(statusCode)
                + '. '
                + message;
 
            logRecord.Timestamp__c = System.now();
 
            insert logRecord;
 
        } catch (Exception logException) {
 
            System.debug(
                'Integration Log Error: '
                + logException.getMessage()
            );
        }
    }
}