import json
import logging
import httpx
from urllib.parse import urlparse

import config
from receipt import validate_callback, map_callback_to_receipt, sign_receipt
from observability import ProbeHandler, Server, gateway_ready, log

class AdapterHandler(ProbeHandler):
    def log_message(self, format, *args):
        pass

    def do_POST(self):
        # The provider sends unsigned callbacks; the capability path is its access boundary.
        path = urlparse(self.path).path
        expected_path = f"/callbacks/provider-v02/{config.PROVIDER_CALLBACK_CAPABILITY}"
        
        if not config.PROVIDER_CALLBACK_CAPABILITY or path != expected_path:
            self.send_response(404)
            self.end_headers()
            return
            
        content_length = self.headers.get('Content-Length')
        if not content_length:
            self.send_response(400)
            self.end_headers()
            return
            
        try:
            length = int(content_length)
        except ValueError:
            self.send_response(400)
            self.end_headers()
            return
            
        if length < 0 or length > 65536:
            self.send_response(400)
            self.end_headers()
            return
            
        body = self.rfile.read(length)
        
        try:
            callback_data = validate_callback(body)
        except ValueError:
            log("receipt.invalid", "WARNING", errorCode="payload.invalid")
            self.send_response(400)
            self.end_headers()
            return
            
        # Send these exact signed bytes; the API verifies HMAC before JSON parsing.
        receipt = map_callback_to_receipt(callback_data)
        body_bytes, signature = sign_receipt(receipt, config.PROVIDER_HMAC_SECRET)
        
        headers = {
            "Authorization": f"Bearer {config.PROVIDER_CALLBACK_TOKEN}",
            "Content-Type": "application/json",
            "Idempotency-Key": receipt["messageId"],
            "X-Action-Version": "1",
            "X-Provider-Signature": signature
        }
        
        try:
            # The provider attempt budget is for dispatcher delivery. The API
            # needs its own timeout, including the first request after restart.
            with httpx.Client(timeout=5.0) as client:
                response = client.post(
                    config.RECEIPT_API_URL, 
                    content=body_bytes,
                    headers=headers
                )
                log("receipt.forwarded", "INFO" if response.is_success else "WARNING",
                    messageId=receipt["messageId"], externalRequestId=receipt["externalRequestId"],
                    requestId=receipt["messageId"], httpStatus=response.status_code)
                self.send_response(response.status_code)
                # httpx decodes response bodies; upstream length/encoding headers no longer apply.
                for k, v in response.headers.items():
                    if k.lower() not in ('content-length', 'content-encoding', 'transfer-encoding'):
                        self.send_header(k, v)
                self.end_headers()
                self.wfile.write(response.content)
        except httpx.RequestError:
            log("receipt.forward_failed", "WARNING", messageId=receipt["messageId"],
                externalRequestId=receipt["externalRequestId"], errorCode="dependency.unavailable")
            self.send_response(503)
            self.send_header("Content-Type", "application/json")
            self.end_headers()
            self.wfile.write(json.dumps({"status": "error", "code": "dependency.unavailable"}).encode('utf-8'))

def main():
    # httpx INFO includes the target URL; do not log capability URLs or headers.
    logging.getLogger("httpx").setLevel(logging.WARNING)
    logging.getLogger("httpcore").setLevel(logging.WARNING)
    port = 8082
    server = Server(('', port), AdapterHandler)
    server.ready = gateway_ready
    log("adapter.started", port=port)
    try:
        server.serve_forever()
    except KeyboardInterrupt:
        pass
    finally:
        server.server_close()

if __name__ == '__main__':
    main()
