import boto3
import os

def create_vpc(session: boto3.Session, name: str) -> dict:
    # create a new vpc
    ec2 = session.client(
        "ec2",
        endpoint_url=os.environ["AWS_ENDPOINT_URL"],
    )

    response = ec2.create_vpc(
        CidrBlock="10.0.0.0/16",
        TagSpecifications=[
            {
                "ResourceType": "vpc",
                "Tags": [
                    {
                        "Key": "Name",
                        "Value": name,
                    }
                ],
            }
        ],
    )

    vpc = response["Vpc"]

    print(f"Created VPC with ID: {vpc['VpcId']}")

    return vpc
