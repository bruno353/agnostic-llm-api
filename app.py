from flask import Flask, request, Response, stream_with_context
import requests
import os
import logging

app = Flask(__name__)

OLLAMA_URL = "http://localhost:11434"
API_KEY = os.environ.get('API_KEY')

if not API_KEY:
    raise ValueError("API_KEY environment variable not set")

logging.basicConfig(level=logging.INFO)

# If you want to allow any IP, leave this list empty
ALLOWED_IPS = [
    # "34.82.208.207",
    # "::1",
]

def validate_ip(ip):
    return len(ALLOWED_IPS) == 0 or ip in ALLOWED_IPS

def validate_api_key(auth_header):
    return auth_header == f"Bearer {API_KEY}"

@app.route('/<path:path>', methods=['GET', 'POST', 'PUT', 'DELETE'])
def proxy(path):
    ip = request.headers.get('X-Forwarded-For', request.remote_addr)
    logging.info(f"New req for python - Server called from IP: {ip}")
    
    if not validate_ip(ip):
        logging.warning(f"Invalid IP: {ip}")
        return "Unauthorized", 401
    
    if not validate_api_key(request.headers.get('Authorization')):
        logging.warning(f"Invalid API key from IP: {ip}")
        return "Unauthorized", 401

    logging.info(f"Path: {path}")

    url = f"{OLLAMA_URL}/{path}"
    headers = {key: value for (key, value) in request.headers if key != 'Host'}
    
    logging.info(f"Forwarding to: {url}")
    
    resp = requests.request(
        method=request.method,
        url=url,
        headers=headers,
        data=request.get_data(),
        cookies=request.cookies,
        stream=True
    )

    logging.info(f"Ollama response status: {resp.status_code}")

    def generate():
        for chunk in resp.iter_content(chunk_size=1024):
            yield chunk

    return Response(stream_with_context(generate()), 
                    content_type=resp.headers.get('Content-Type'),
                    status=resp.status_code)

if __name__ == '__main__':
    app.run(host='0.0.0.0', port=8080, debug=True)