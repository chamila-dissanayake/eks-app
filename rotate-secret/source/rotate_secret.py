import boto3
import json
import os
import logging
import secrets
import string

# Set up logging
logger = logging.getLogger()
logger.setLevel(logging.INFO)

secret_id  = os.environ.get('SECRET_ID')
secret_key = os.environ.get('SECRET_KEY')
secret_len = os.environ.get('SECRET_LENGTH', 64)

def generate_new_secret_value(length=secret_len):
    """Generate a random secret value."""
    characters = string.ascii_letters + string.digits + "!@#$%^&"
    return ''.join(secrets.choice(characters) for _ in range(length))

def lambda_handler(event, context):
    """AWS Lambda handler to update a secret in AWS Secrets Manager."""
    try:
        # Initialize Secrets Manager client
        client = boto3.client('secretsmanager')

        # Retrieve the current secret
        logger.info(f"Retrieving secret: {secret_id}")
        response = client.get_secret_value(SecretId=secret_id)
        current_secret = json.loads(response['SecretString'])

        # Generate new secret value
        new_secret_value = generate_new_secret_value()
        logger.info(f"Generated new secret value for key: {secret_key}")

        # Update the secret dictionary
        current_secret[secret_key] = new_secret_value

        # Update the secret in Secrets Manager
        client.put_secret_value(
            SecretId=secret_id,
            SecretString=json.dumps(current_secret)
        )
        logger.info(f"Successfully updated secret: {secret_id}")

        return {
            'statusCode': 200,
            'body': json.dumps(f"Secret {secret_id} updated successfully")
        }

    except client.exceptions.ResourceNotFoundException:
        logger.error(f"Secret {secret_id} not found")
        return {
            'statusCode': 404,
            'body': json.dumps(f"Secret {secret_id} not found")
        }
    except Exception as e:
        logger.error(f"Error updating secret: {str(e)}")
        return {
            'statusCode': 500,
            'body': json.dumps(f"Error updating secret: {str(e)}")
        }

if __name__ == "__main__":
    # For local testing
    lambda_handler({}, {})