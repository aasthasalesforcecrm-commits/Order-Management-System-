/**
 * Run/schedule this class once to start the repeating sync chain.
 * The batch schedules the next run 15 minutes after it finishes.
 */
global without sharing class OMSProductSyncScheduler implements Schedulable {
    global void execute(SchedulableContext context) {
         Database.executeBatch(new OMSProductSyncBatch(),100);
    }
}