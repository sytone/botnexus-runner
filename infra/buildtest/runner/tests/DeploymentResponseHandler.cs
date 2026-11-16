using System;
using System.IO;
using System.Linq;
using System.Net;
using System.Net.Http;
using System.Text.Json.Nodes;
using System.Threading;
using System.Threading.Tasks;
// In-memory HTTP fixture. Never opens a socket or obtains real credentials.
public sealed class DeploymentResponseHandler : HttpMessageHandler {
 protected override async Task<HttpResponseMessage> SendAsync(HttpRequestMessage request, CancellationToken token) {
  string root = Environment.GetEnvironmentVariable("DEPLOY_ROOT");
  string mode = Environment.GetEnvironmentVariable("DEPLOY_FIXTURE") ?? "success";
  string method = request.Method.Method.ToLowerInvariant();
  string url = request.RequestUri.AbsoluteUri;
  bool operation = request.RequestUri.AbsolutePath.Contains("/operationStatuses/");
  string[] headers = request.Headers.TryGetValues("If-Match", out var values) ? values.ToArray() : Array.Empty<string>();
  var record = new string[] {"http", "--method", method, "--url", url, "--subscription", "11111111-1111-1111-1111-111111111111"}.Concat(headers.Select(h => "If-Match=" + h)).ToArray();
  File.AppendAllText(Path.Combine(root,"calls.jsonl"), System.Text.Json.JsonSerializer.Serialize(record)+"\n");
  if (request.Headers.Authorization?.Parameter != "SYNTHETIC_DEPLOY_TOKEN") throw new Exception("Missing synthetic token");
  if (operation) {
   if (mode == "statusdenied") return new HttpResponseMessage(HttpStatusCode.Forbidden) {Content=new StringContent("{}")};
   string state = mode == "pending" ? "Running" : mode == "opfailed" ? "Failed" : "Succeeded";
   return new HttpResponseMessage(HttpStatusCode.OK) {Content=new StringContent("{\"status\":\""+state+"\"}")};
  }
  string jobfile=Path.Combine(root,"job.json");
  var job=JsonNode.Parse(File.ReadAllText(jobfile));
  if (method == "patch") {
   if (!File.Exists(Path.Combine(root,"private-operation.json"))) throw new Exception("Fence absent before write");
   var body=JsonNode.Parse(await request.Content.ReadAsStringAsync(token));
   if (body.AsObject().Count != 1 || body["properties"].AsObject().Count != 1 || body["properties"]["template"].AsObject().Count != 1 || body["properties"]["template"]["containers"] is not JsonArray) throw new Exception("Unexpected patch scope");
   File.WriteAllText(Path.Combine(root,"patch.json"),body.ToJsonString());
   job["properties"]["template"]["containers"]=body["properties"]["template"]["containers"].DeepClone();
   if (mode != "async") File.WriteAllText(jobfile,job.ToJsonString());
   if (mode == "drift") {job["properties"]["template"]["containers"][0]["resources"]["memory"]="1Gi"; File.WriteAllText(jobfile,job.ToJsonString());}
   if (mode == "unknown") throw new IOException("PRIVATE_DEPLOY_SENTINEL_87352");
   if (mode == "timeout") await Task.Delay(60000,token);
   if (mode == "accepted200") job["properties"]["provisioningState"]="Accepted";
   if (mode == "wrongimage200") job["properties"]["template"]["containers"][0]["image"]="private.example.invalid/runner@sha256:"+new string('b',64);
   if (mode == "wrongtarget200") job["id"]="/wrong";
   int status=mode == "http500" ? 500 : mode.StartsWith("async") || mode == "priority" || mode == "missingref" || mode == "unsafe" ? 202 : 200;
   var response=new HttpResponseMessage((HttpStatusCode)status) {Content=new StringContent(mode == "partialbody" ? "{bad" : mode == "ambiguous200" ? "{}" : job.ToJsonString())};
   string op="https://management.azure.com/subscriptions/11111111-1111-1111-1111-111111111111/providers/Microsoft.App/locations/westus/operationStatuses/operation-1?api-version=2024-03-01";
   if (status == 202 && mode != "missingref") response.Headers.TryAddWithoutValidation(mode == "asynclocation" ? "Location" : "Azure-AsyncOperation",mode == "unsafe" ? "https://evil.invalid/private" : op);
   if (mode == "priority") response.Headers.TryAddWithoutValidation("Location", "https://management.azure.com"+job["id"].GetValue<string>()+"?api-version=2024-03-01");
   if (mode == "readbackdrift") {job["properties"]["template"]["containers"][0]["resources"]["memory"]="1Gi"; File.WriteAllText(jobfile,job.ToJsonString());}
   return response;
  }
  if (mode == "failure") return new HttpResponseMessage(HttpStatusCode.Forbidden) {Content=new StringContent("{}")};
  if (mode == "identity") job["id"]="/wrong/PRIVATE_DEPLOY_SENTINEL_87352";
  return new HttpResponseMessage(HttpStatusCode.OK) {Content=new StringContent(mode == "malformed" ? "{PRIVATE_DEPLOY_SENTINEL_87352" : mode == "highoutput" || mode == "dualoutput" ? new string('x',1048577) : job.ToJsonString())};
 }
}
