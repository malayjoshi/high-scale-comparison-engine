
import boto3
import os
from load_env import load_env
from resources import create_api_gateway
from create_vpc import create_vpc
from pathlib import Path


load_env(Path(__file__).with_name(".env"))

session = boto3.Session(
    profile_name=os.environ["AWS_PROFILE"],
    region_name=os.environ["AWS_REGION"],
)

if __name__ == "__main__":
    vpc = create_vpc(session, "comparison-engine-vpc")
    api_gateway = create_api_gateway(session, "comparison-engine-api")
