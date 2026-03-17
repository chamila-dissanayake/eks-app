import boto3
import json
import os
import logging
import requests

# Set up logging
logger = logging.getLogger()
logger.setLevel(logging.INFO)

api_url    = os.environ.get('API_URL')
secret_id  = os.environ.get('SECRET_ID')
secret_key = os.environ.get('SECRET_KEY')
timeout    = int(os.environ.get('TIMEOUT', 30))

def call_api(api_url, auth_token, payload=None, headers=None):
    """Call API with authentication token."""
    try:
        headers = {}

        # Add authentication if token provided
        if auth_token:
            #encoded_token = urllib.parse.quote(auth_token, safe='')
            #encoded_token = quote(auth_token, safe='')
            headers["Authorization"] = f"{auth_token}"

        logger.info(f"Request URL: {api_url}")
        #logger.info(f"Request Headers: {headers}")

        response = requests.post(
            api_url,
            json=payload,
            headers=headers,
            timeout=timeout
        )

        response.raise_for_status()
        logger.info(f"POST API call to {api_url} succeeded with status code {response.status_code}")

        #try:
            #return response.json()
        #except json.JSONDecodeError:
            #return response.text

        return response.text

    except requests.exceptions.RequestException as e:
        logger.error(f"POST API call with auth failed: {str(e)}")
        raise

def lambda_handler(event, context):
    """AWS Lambda handler to call an API with a secret."""
    try:
        # Initialize Secrets Manager client
        client = boto3.client('secretsmanager')

        # Retrieve the current secret
        logger.info(f"Retrieving secret: {secret_id}")
        response = client.get_secret_value(SecretId=secret_id)
        secret = json.loads(response['SecretString'])

    except client.exceptions.ResourceNotFoundException:
        logger.error(f"Secret {secret_id} not found")
        return {
            'statusCode': 404,
            'body': json.dumps(f"Secret {secret_id} not found")
        }

    # Call the API with the new secret value
    #encoded_token = secret[secret_key].encode('utf-8').decode('ascii')
    api_response = call_api(api_url, auth_token=secret[secret_key])
    logger.info(f"API response: {api_response}")

if __name__ == "__main__":
    # For local testing
    lambda_handler({}, {})