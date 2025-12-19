import jwt
import datetime
import sys
import json

def generate_token(organization_id, environment_id, secret):
    utc_now = datetime.datetime.now(datetime.timezone.utc)
    # Token valid for 1 hour
    payload = {
        "iss": "graphlit",
        "sub": organization_id,
        "aud": "https://data-scus.graphlit.io",
        "exp": utc_now + datetime.timedelta(hours=1),
        "iat": utc_now,
        "https://graphlit.io/jwt/claims": {
            "x-graphlit-organization-id": organization_id,
            "x-graphlit-environment-id": environment_id,
            "x-graphlit-role": "Owner"
        }
    }
    token = jwt.encode(payload, secret, algorithm="HS256")
    return token

if __name__ == "__main__":
    if len(sys.argv) < 4:
        print("Usage: python gen_token.py <org_id> <env_id> <secret>")
        sys.exit(1)
    
    org_id = sys.argv[1]
    env_id = sys.argv[2]
    secret = sys.argv[3]
    
    try:
        print(generate_token(org_id, env_id, secret))
    except Exception as e:
        print(f"Error: {str(e)}", file=sys.stderr)
        sys.exit(1)
