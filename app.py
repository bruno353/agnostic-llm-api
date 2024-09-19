from flask import Flask, request, Response, stream_with_context
import requests
import os
import logging

app = Flask(__name__)

OLLAMA_URL = "http://localhost:11434"
API_KEY = os.environ.get('API_KEY')

if not API_KEY:
    raise ValueError("API_KEY environment variable not set")

# Se você quiser permitir qualquer IP, deixe esta lista vazia
ALLOWED_IPS = [
    # "34.82.208.207",
    # "::1",
]

logging.basicConfig(level=logging.INFO)

def validate_ip(ip):
    return len(ALLOWED_IPS) == 0 or ip in ALLOWED_IPS

def validate_api_key(auth_header):
    return auth_header == f"Bearer {API_KEY}"

@app.route('/api/<path:path>', methods=['GET', 'POST', 'PUT', 'DELETE'])
def proxy(path):
    ip = request.headers.get('X-Forwarded-For', request.remote_addr)
    logging.info(f"New req python - Server called from IP: {ip}")

    if not validate_ip(ip):
        logging.info(f"Invalid ip: {ip}")
        return "Unauthorized", 401

    if not validate_api_key(request.headers.get('Authorization')):
        logging.info(f"Invalid api key: {ip}")
        return "Unauthorized", 401

    logging.info(f"Received new request: {request.method} {request.path}")
    logging.info(f"Request body: {request.get_data(as_text=True)}")

    url = f"{OLLAMA_URL}/{path}"
    headers = {key: value for (key, value) in request.headers if key != 'Host'}
    
    resp = requests.request(
        method=request.method,
        url=url,
        headers=headers,
        data=request.get_data(),
        cookies=request.cookies,
        stream=True
    )

    def generate():
        for chunk in resp.iter_content(chunk_size=1024):
            yield chunk

    return Response(stream_with_context(generate()), content_type=resp.headers['Content-Type'])

if __name__ == '__main__':
    app.run(host='0.0.0.0', port=8080)