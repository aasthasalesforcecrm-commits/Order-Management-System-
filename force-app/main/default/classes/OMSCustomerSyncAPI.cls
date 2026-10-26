@RestResource(urlMapping='/oms/customers')
global with sharing class OMSCustomerSyncAPI {
 
    @HttpPost
    global static void receiveCustomers() {
 
        RestResponse response = RestContext.response;
 
        response.addHeader(
            'Content-Type',
            'application/json'
        );
 
        try {
 
            // STEP 1: Read the incoming request.
            if (RestContext.request.requestBody == null) {
 
                sendResponse(
                    400,
                    false,
                    'Request body is missing.',
                    0,
                    new List<String>()
                );
 
                return;
            }
 
            String requestBody =
                RestContext.request.requestBody.toString();
 
            Object parsedData =
                JSON.deserializeUntyped(requestBody);
 
            if (!(parsedData instanceof List<Object>)) {
 
                sendResponse(
                    400,
                    false,
                    'Expected a list of customers.',
                    0,
                    new List<String>()
                );
 
                return;
            }
 
            List<Object> incomingCustomers =
                (List<Object>) parsedData;
 
            // STEP 2: Prepare Accounts for upsert.
            Map<String, Account> accountsByErpId =
                new Map<String, Account>();
 
            List<String> errors = new List<String>();
 
            for (Object item : incomingCustomers) {
 
                if (!(item instanceof Map<String, Object>)) {
 
                    errors.add(
                        'Invalid customer data received.'
                    );
 
                    continue;
                }
 
                Map<String, Object> data =
                    (Map<String, Object>) item;
 
                String erpCustomerId =
                    getString(data, 'erpCustomerId');
 
                String customerName =
                    getString(data, 'name');
 
                if (
                    String.isBlank(erpCustomerId) ||
                    String.isBlank(customerName)
                ) {
 
                    errors.add(
                        'Customer skipped because ERP Customer ID ' +
                        'or Name is missing.'
                    );
 
                    continue;
                }
 
                Account acc = new Account();
 
                acc.ERP_Customer_ID__c = erpCustomerId;
                acc.Name = customerName;
 
                acc.Phone = getString(data, 'phone');
                acc.Website = getString(data, 'website');
                acc.Industry = getString(data, 'industry');
 
                acc.BillingStreet =
                    getString(data, 'billingStreet');
 
                acc.BillingCity =
                    getString(data, 'billingCity');
 
                acc.BillingState =
                    getString(data, 'billingState');
 
                acc.BillingPostalCode =
                    getString(data, 'billingPostalCode');
 
                acc.BillingCountry =
                    getString(data, 'billingCountry');
 
                // Use the ERP ID to prevent duplicate Accounts.
                accountsByErpId.put(
                    erpCustomerId,
                    acc
                );
            }
 
            List<Account> accountsToUpsert =
                accountsByErpId.values();
 
            if (accountsToUpsert.isEmpty()) {
 
                sendResponse(
                    400,
                    false,
                    'No valid customer records were received.',
                    0,
                    errors
                );
 
                return;
            }
 
            // STEP 3: Create new Accounts or update existing Accounts.
            Database.UpsertResult[] results =
                Database.upsert(
                    accountsToUpsert,
                    Account.ERP_Customer_ID__c,
                    false
                );
 
            Integer successCount = 0;
            Integer failureCount = 0;
 
            // STEP 4: Check each Account result.
            for (
                Integer i = 0;
                i < results.size();
                i++
            ) {
 
                if (results[i].isSuccess()) {
 
                    successCount++;
 
                } else {
 
                    failureCount++;
 
                    for (
                        Database.Error err :
                        results[i].getErrors()
                    ) {
 
                        errors.add(
                            'Customer ' +
                            accountsToUpsert[i]
                                .ERP_Customer_ID__c +
                            ' failed: ' +
                            err.getMessage()
                        );
                    }
                }
            }
 
            // STEP 5: Return the result to the ERP org.
            Boolean allSuccessful =
                failureCount == 0 &&
                errors.isEmpty();
 
            sendResponse(
                200,
                allSuccessful,
                allSuccessful
                    ? 'Customers synchronized successfully.'
                    : 'Some customers could not be synchronized.',
                successCount,
                errors
            );
 
        } catch (Exception e) {
 
            sendResponse(
                500,
                false,
                'Customer synchronization failed: ' +
                e.getMessage(),
                0,
                new List<String>()
            );
        }
    }
 
    // Read a value from the JSON request.
    private static String getString(
        Map<String, Object> data,
        String fieldName
    ) {
 
        Object value = data.get(fieldName);
 
        return value == null
            ? null
            : String.valueOf(value);
    }
 
    // Return a consistent JSON response.
    private static void sendResponse(
        Integer statusCode,
        Boolean success,
        String message,
        Integer recordsProcessed,
        List<String> errors
    ) {
 
        RestResponse response = RestContext.response;
 
        response.statusCode = statusCode;
 
        Map<String, Object> responseData =
            new Map<String, Object>();
 
        responseData.put('success', success);
        responseData.put('message', message);
 
        responseData.put(
            'recordsProcessed',
            recordsProcessed
        );
 
        responseData.put('errors', errors);
 
        response.responseBody = Blob.valueOf(
            JSON.serialize(responseData)
        );
    }
}