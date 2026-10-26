global with sharing class OMSCustomerSyncScheduler implements Schedulable {
    global void execute(SchedulableContext sc)//starts customer sync batch 
    {
        Database.executeBatch(new OMSCustomerSyncBatch(),100);
    }
    
}