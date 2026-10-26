public class ExternalClientApp {
    public static void myTestingMethod()
    {
        HttpRequest req = new HttpRequest();
        req.setEndpoint('Callout:ERP/services/data/v67.0/sobjects/Account/001gK00001cTpdRQAS');
        req.setMethod('GET');
        Http http = new Http();
        HttpResponse res = http.send(req);
        System.debug(res.getBody());
    }


}