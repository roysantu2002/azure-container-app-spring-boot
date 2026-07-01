from flask import Flask, jsonify
import requests
import socket
import os

app = Flask(__name__)

# In same Container Apps environment, app-1 is reachable via its name
APP1_URL = os.environ.get('APP1_URL', 'http://app-1')

@app.route('/')
def home():
    return jsonify({
        "app": "app-2",
        "message": "Hello from App 2! Call /fetch-from-app1 to see inter-app communication."
    })

@app.route('/fetch-from-app1')
def fetch_from_app1():
    try:
        response = requests.get(f"{APP1_URL}/", timeout=5)
        app1_data = response.json()
        return jsonify({
            "app": "app-2",
            "hostname": socket.gethostname(),
            "message": "App 2 successfully fetched data from App 1",
            "app1_url_used": APP1_URL,
            "app1_response": app1_data
        })
    except Exception as e:
        return jsonify({
            "app": "app-2",
            "error": str(e),
            "app1_url_used": APP1_URL
        }), 500

@app.route('/health')
def health():
    return jsonify({"status": "healthy", "app": "app-2"})

if __name__ == '__main__':
    app.run(host='0.0.0.0', port=8080, debug=False)