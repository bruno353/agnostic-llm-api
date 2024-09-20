from flask import Flask, request, Response, stream_with_context, jsonify
import requests
import os
import logging
import whisper
import tempfile
import torch
import whisperx
import gc
from pyannote.audio import Pipeline

app = Flask(__name__)

OLLAMA_URL = "http://localhost:11434"
API_KEY = os.environ.get('API_KEY')
HF_TOKEN = os.environ.get('HF_TOKEN')  # Adicione esta linha no setup.sh

if not API_KEY:
    raise ValueError("API_KEY environment variable not set")

if not HF_TOKEN:
    raise ValueError("HF_TOKEN environment variable not set")

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
    logging.info(f"New req nmm for python - Server called from IP: {ip}")
    
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

@app.route('/transcribe', methods=['POST'])
def transcribe_audio():
    ip = request.headers.get('X-Forwarded-For', request.remote_addr)
    logging.info(f"New transcription request from IP: {ip}")
    
    if not validate_ip(ip):
        logging.warning(f"Invalid IP: {ip}")
        return "Unauthorized", 401
    
    if not validate_api_key(request.headers.get('Authorization')):
        logging.warning(f"Invalid API key from IP: {ip}")
        return "Unauthorized", 401

    if 'file' not in request.files:
        return jsonify({"error": "No file part"}), 400
    
    file = request.files['file']
    if file.filename == '':
        return jsonify({"error": "No selected file"}), 400

    if file:
        # Salvar o arquivo temporariamente
        with tempfile.NamedTemporaryFile(delete=False, suffix='.wav') as temp_file:
            file.save(temp_file.name)
            temp_filename = temp_file.name

        try:
            # Carregar o modelo Whisper (medium)
            device = "cuda" if torch.cuda.is_available() else "cpu"
            logging.info(f"Using device: {device}")
            model = whisper.load_model("medium").to(device)
            
            # Transcrever o áudio
            logging.info("Starting transcription...")
            result = model.transcribe(temp_filename)
            logging.info("Transcription completed")
            
            return jsonify({"transcription": result["text"]})
        except Exception as e:
            logging.error(f"Error during transcription: {str(e)}")
            return jsonify({"error": "Transcription failed"}), 500
        finally:
            # Remover o arquivo temporário
            os.unlink(temp_filename)

    return jsonify({"error": "File processing failed"}), 500

@app.route('/transcribe_diarize', methods=['POST'])
def transcribe_diarize_audio():
    ip = request.headers.get('X-Forwarded-For', request.remote_addr)
    logging.info(f"New diarization request from IP: {ip}")
    
    if not validate_ip(ip):
        logging.warning(f"Invalid IP: {ip}")
        return "Unauthorized", 401
    
    if not validate_api_key(request.headers.get('Authorization')):
        logging.warning(f"Invalid API key from IP: {ip}")
        return "Unauthorized", 401

    if 'file' not in request.files:
        return jsonify({"error": "No file part"}), 400
    
    file = request.files['file']
    if file.filename == '':
        return jsonify({"error": "No selected file"}), 400

    if file:
        with tempfile.NamedTemporaryFile(delete=False, suffix='.wav') as temp_file:
            file.save(temp_file.name)
            temp_filename = temp_file.name

        try:
            device = "cuda" if torch.cuda.is_available() else "cpu"
            logging.info(f"Using device: {device}")
            
            # 1. Transcribe with WhisperX
            model = whisperx.load_model("large-v2", device, compute_type="float16")
            audio = whisperx.load_audio(temp_filename)
            result = model.transcribe(audio, batch_size=16)
            logging.info("Transcription completed")

            # 2. Align whisper output
            model_a, metadata = whisperx.load_align_model(language_code=result["language"], device=device)
            result = whisperx.align(result["segments"], model_a, metadata, audio, device, return_char_alignments=False)
            logging.info("Alignment completed")

            # 3. Assign speaker labels using local model
            diarize_model = Pipeline.from_pretrained("pyannote/speaker-diarization@2.1", use_auth_token=False)
            diarize_model = diarize_model.to(device)
            diarize_segments = diarize_model(temp_filename)
            result = whisperx.assign_word_speakers(diarize_segments, result)
            logging.info("Diarization completed")

            return jsonify({"result": result})
        except Exception as e:
            logging.error(f"Error during transcription and diarization: {str(e)}")
            return jsonify({"error": "Transcription and diarization failed"}), 500
        finally:
            os.unlink(temp_filename)
            gc.collect()
            torch.cuda.empty_cache()

    return jsonify({"error": "File processing failed"}), 500

app.config['MAX_CONTENT_LENGTH'] = 10 * 1024 * 1024  # 10 MB

if __name__ == '__main__':
    app.run(host='0.0.0.0', port=8080, debug=True)