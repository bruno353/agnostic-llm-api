# Agnostic Ollama API Setup

The main goal of this content is to provide users with a **seamless way to deploy their own LLM with an API interface on any cloud provider**, ensuring that you are not dependent on any internal services (such as AWS SageMaker). This allows you to maintain full control over your model while reducing costs at scale by avoiding third-party APIs.
</br>
</br>
Main.go file forked from [developersdigest](https://github.com/developersdigest/aws-ec2-cuda-ollama)
</br>
### Key technologies include:
- Ollama for LLM management and inference, enabling GPU and CPU support.
- Go (Golang) for building a fast and lightweight API service.
- Nginx for managing secure HTTPS connections and acting as a reverse proxy.
- Certbot for automatically obtaining and renewing SSL certificates from Let's Encrypt.
- Systemd to manage services like the LLM API and Ollama server as background processes.
</br>
For this tutorial example we are using the AWS g4 ec2 instance.
</br>
You will: Deploy your EC2 instance, create an Elastic IP, attach it to your domain, run the script with your environment variables, pull your preferred LLM, and start running your API.

## 0. Configure setup.sh ENVs

The following variables need to be set by you:
   - DOMAIN_NAME: Your API`s domain
   - API_KEY: Secret key to connect with your model through the API
   - EMAIL: Your email to link with certbot
   - MODEL_NAME: The [model](https://ollama.com/library) to run

## 1. Launch EC2 Instance and Elastic API

a. Launch EC2:
- AMI: Search for and select "Deep Learning Base OSS Nvidia Driver GPU AMI (Ubuntu 22.04)"
- Instance type: g4dn.xlarge (4 vCPUs, 16 GiB Memory, 1 GPU)
- Network settings:
   - Allow SSH (port 22) from your IP
   - Allow HTTPS and HTTP connections

b. Configure Elastic IP:
- Under Network & Security in EC2, go to Elastic IPs
- Allocate an Elastic IP address and attach it to your newly created EC2 instance
- In your domain manager, link the created IP to the domain name you want to use for your API
  
## 2. Connect to EC2 Instance

```
ssh -i your-key.pem ubuntu@your-ec2-public-ip
```

## 3. Set the bash script
a. Open file
```
nano setup.sh
```
b. Copy your [script](https://github.com/bruno353/agnostic-llm-api/blob/main/setup.sh) and paste it (CTRL + X to save)
c. Turn it exec
```
chmod +x setup.sh
```
d. Run
```
sudo ./setup.sh
```
## 4. Check ollama model
Sometimes ollama isnt able to pull the model within the script, so you need to check if it was pull succesfully
a. Check if the model exists
```
ollama list
```
- If your model isnt listed, run:
   ```
   ollama pull "YOUR_MODEL_NAME"
   ```

## 5. Testing API

To test your API, try:
```
curl https://your_domain.com/v1/chat/completions \
-H "Content-Type: application/json" \
-H "Authorization: Bearer your_api_key" \
-d '{
  "model": "gemma2:2b",
  "messages": [
    {"role": "user", "content": "Tell me a story about a brave knight"}
  ],
  "stream": true
}'
```
- make sure to change the model for the one you pulled in the instance

## 6. Utils and Logs
a. To check if your instance has a working nvidia gpu:
   ```
   nvidia-smi
   ```
b. To check ollama server logs and status:
   ```
   sudo journalctl -u ollama.service -f
   ```
   ```
   sudo systemctl status ollama.service
   ```
C. To check app status:
   ```
   sudo journalctl -u llm-app.service -f
   ```
d. To check machine storage:
   ```
   df -h
   ```