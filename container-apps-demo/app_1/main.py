from flask import Flask, jsonify
import socket

app = Flask(__name__)

@app.route('/')
def home():
    return jsonify({
        "app": "app-1",
        "message": "Hello from App 1!",
        "hostname": socket.gethostname()
    })

@app.route('/health')
def health():
    return jsonify({"status": "healthy", "app": "app-1"})

if __name__ == '__main__':
    app.run(host='0.0.0.0', port=8080, debug=False)