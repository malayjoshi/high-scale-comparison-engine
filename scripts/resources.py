import boto3
import os

def create_api_gateway(session: boto3.Session, name: str) -> dict:
    api_gateway = session.client(
        "apigateway",
        endpoint_url = os.environ["AWS_ENDPOINT_URL"],
        region_name = os.environ["AWS_REGION"],
    )

    response = api_gateway.create_rest_api(
        name = name,
        description = f"API Gateway for {name}",
    )

    print(f"Created API Gateway with ID: {response['id']}")
    return response
