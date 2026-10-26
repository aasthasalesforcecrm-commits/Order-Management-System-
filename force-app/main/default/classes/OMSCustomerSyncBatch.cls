global with sharing class OMSCustomerSyncBatch
    implements Database.Batchable<CustomerSalesDTO>,
               Database.AllowsCallouts,
               Database.Stateful {
 
    private Datetime startTime;
    private Integer totalRecordsReceived = 0;
    private Integer recordsProcessed = 0;
    private Boolean calloutFailed = false;
    private String errorDetails = '';
 
    // STEP 1: Retrieve customers from ERP.
    public Iterable<CustomerSalesDTO> start(
        Database.BatchableContext bc
    ) {
 
        startTime = System.now();
 
        HttpRequest request = new HttpRequest();
 
        request.setEndpoint(
            'callout:ERP/services/apexrest/oms/customers'
        );
 
        request.setMethod('GET');
        request.setTimeout(120000);
 
        try {
 
            Http http = new Http();
            HttpResponse response = http.send(request);
 
            System.debug(
                'Customer API status: ' + response.getStatusCode()
            );
 
            // Handle an unsuccessful API response.
            if (response.getStatusCode() != 200) {
 
                calloutFailed = true;
 
                addError(
                    'Customer API failed. HTTP Status: '
                    + response.getStatusCode()
                    + '. Response: '
                    + response.getBody()
                );
 
                return new List<CustomerSalesDTO>();
            }
 
            // IMPORTANT: Deserialize when the response is successful.
            List<CustomerSalesDTO> customers =
                (List<CustomerSalesDTO>) JSON.deserialize(
                    response.getBody(),
                    List<CustomerSalesDTO>.class
                );
 
            if (customers == null) {
                return new List<CustomerSalesDTO>();
            }
 
            System.debug(
                'Customers received from ERP: ' + customers.size()
            );
 
            return customers;
 
        } catch (Exception e) {
 
            calloutFailed = true;
 
            addError(
                'Customer API callout or response failed: '
                + e.getMessage()
            );
 
            return new List<CustomerSalesDTO>();
        }
    }
 
    // STEP 2: Create or update Sales Accounts.
    public void execute(
        Database.BatchableContext bc,
        List<CustomerSalesDTO> scope
    ) {
 
        totalRecordsReceived += scope.size();
 
        Map<String, Account> accountByErpId =
            new Map<String, Account>();
 
        for (CustomerSalesDTO customer : scope) {
 
            if (
                customer == null
                || String.isBlank(customer.erpCustomerId)
                || String.isBlank(customer.name)
            ) {
 
                addError(
                    'Account not processed: ERP customer ID or Name is missing.'
                );
 
                continue;
            }
 
            Account acc = new Account();
 
            acc.ERP_Customer_ID__c = customer.erpCustomerId;
            acc.Name = customer.name;
            acc.Phone = customer.phone;
            acc.Website = customer.website;
            acc.Industry = customer.industry;
            acc.BillingStreet = customer.billingStreet;
            acc.BillingCity = customer.billingCity;
            acc.BillingState = customer.billingState;
            acc.BillingPostalCode = customer.billingPostalCode;
            acc.BillingCountry = customer.billingCountry;
 
            accountByErpId.put(customer.erpCustomerId, acc);
        }
 
        List<Account> accountsToUpsert =
            accountByErpId.values();
 
        if (accountsToUpsert.isEmpty()) {
            return;
        }
 
        // Partial upsert: one failed Account does not prevent
        // other valid Accounts from being saved.
        Database.UpsertResult[] results = Database.upsert(
            accountsToUpsert,
            Account.ERP_Customer_ID__c,
            false
        );
 
        for (Integer i = 0; i < results.size(); i++) {
 
            if (results[i].isSuccess()) {
 
                recordsProcessed++;
 
                System.debug(
                    'Account synced successfully. Sales Account ID: '
                    + results[i].getId()
                );
 
            } else {
 
                for (Database.Error err : results[i].getErrors()) {
 
                    addError(
                        'Account sync failed for ERP customer ID '
                        + accountsToUpsert[i].ERP_Customer_ID__c
                        + '. Error: '
                        + err.getMessage()
                    );
                }
            }
        }
    }
 
    // STEP 3: Save the sync log.
    public void finish(Database.BatchableContext bc) {
 
        Integer failedCount =
            totalRecordsReceived - recordsProcessed;
 
        if (failedCount < 0) {
            failedCount = 0;
        }
 
        // Count a failed API attempt even when no customer rows
        // were returned.
        if (calloutFailed && failedCount == 0) {
            failedCount = 1;
        }
 
        Sync_Log__c logRecord = new Sync_Log__c(
            Start_Time__c = startTime,
            End_Time__c = System.now(),
            Records_Processed__c = recordsProcessed,
            Records_Failed__c = failedCount,
            Error_Details__c = errorDetails,
            Sync_Type__c = 'Account Sync'
        );
 
        // Check whether the Sync Log itself was inserted.
        Database.SaveResult saveResult =
            Database.insert(logRecord, false);
 
        if (saveResult.isSuccess()) {
 
            System.debug(
                'Account Sync Log created. ID: '
                + saveResult.getId()
            );
 
        } else {
 
            for (Database.Error err : saveResult.getErrors()) {
 
                System.debug(
                    'Account Sync Log insertion failed: '
                    + err.getStatusCode()
                    + ' - '
                    + err.getMessage()
                );
            }
        }
 
        // Schedule the next batch run.
        try {
 
            System.scheduleBatch(
                new OMSCustomerSyncBatch(),
                'OMS Account Sync ' + System.now().getTime(),
                15,
                500
            );
 
        } catch (Exception e) {
 
            System.debug(
                'Could not schedule the next Account Sync: '
                + e.getMessage()
            );
        }
    }
 
    // STEP 4: Collect errors so they can be saved in Sync_Log__c.
    private void addError(String message) {
 
        if (errorDetails == null) {
            errorDetails = '';
        }
 
        if (errorDetails.length() < 28000) {
            errorDetails += message + '\n';
        }
    }
}