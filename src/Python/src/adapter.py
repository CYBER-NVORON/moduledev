import sys
import json
import logging
from http.server import ThreadingHTTPServer, BaseHTTPRequestHandler
import httpx
from urllib.parse import urlparse

import config
from receipt import validate_callback, map_callback_to_receipt, sign_receipt

class AdapterHandler(BaseHTTPRequestHandler):
    def log_message(self, format, *args):
        pass

    def do_POST(self):
        # 1. Routing & Authorization Check
        path = urlparse(self.path).path
        expected_path = f"/callbacks/provider-v02/{config.PROVIDER_CALLBACK_CAPABILITY}"
        
        if not config.PROVIDER_CALLBACK_CAPABILITY or path != expected_path:
            self.send_response(404)
            self.end_headers()
            return
            
        # 2. Extract and strictly validate payload
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
        except ValueError as e:
            logging.error(json.dumps({"error": str(e)}))
            self.send_response(400)
            self.end_headers()
            return
            
        # 3. Transform to unified receipt format and compute HMAC signature
        receipt = map_callback_to_receipt(callback_data)
        body_bytes, signature = sign_receipt(receipt, config.PROVIDER_HMAC_SECRET)
        
        headers = {
            "Authorization": f"Bearer {config.PROVIDER_CALLBACK_TOKEN}",
            "Content-Type": "application/json",
            "Idempotency-Key": receipt["messageId"],
            "X-Action-Version": "1",
            "X-Provider-Signature": signature
        }
        
        # 4. Proxy authenticated request to the Receipt API
        try:
            with httpx.Client(timeout=config.PROVIDER_TIMEOUT) as client:
                response = client.post(
                    config.RECEIPT_API_URL, 
                    content=body_bytes,
                    headers=headers
                )
                self.send_response(response.status_code)
                for k, v in response.headers.items():
                    if k.lower() not in ('content-length', 'content-encoding', 'transfer-encoding'):
                        self.send_header(k, v)
                self.end_headers()
                self.wfile.write(response.content)
        except httpx.RequestError as e:
            self.send_response(503)
            self.send_header("Content-Type", "application/json")
            self.end_headers()
            self.wfile.write(json.dumps({"status": "error", "code": "dependency.unavailable"}).encode('utf-8'))

def main():
    logging.basicConfig(level=logging.INFO, format='%(message)s')
    port = 8082
    server = ThreadingHTTPServer(('', port), AdapterHandler)
    logging.info(json.dumps({"event": "adapter.started", "port": port}))
    try:
        server.serve_forever()
    except KeyboardInterrupt:
        pass
    finally:
        server.server_close()

if __name__ == '__main__':
    main()
