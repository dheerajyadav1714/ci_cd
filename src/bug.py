import requests
from requests.adapters import HTTPAdapter
from urllib3.util.retry import Retry
import os
import time

# --- Configuration ---
# Use environment variables for sensitive or frequently changing values
LOGIN_URL = os.getenv("LOGIN_API_URL", "http://localhost:8000/api/login") # Default to a common dev endpoint
# Initial timeout for a single request attempt
INITIAL_TIMEOUT_SECONDS = int(os.getenv("API_INITIAL_TIMEOUT_SECONDS", "10"))
# Maximum number of retries for transient errors
MAX_RETRIES = int(os.getenv("API_MAX_RETRIES", "5"))
# Factor for exponential backoff between retries (e.g., 0.5, 1, 2, 4 seconds)
BACKOFF_FACTOR = float(os.getenv("API_BACKOFF_FACTOR", "1"))
# --- End Configuration ---

def login(username, password):
    """
    Attempts to log in to the API endpoint with retry mechanism and increased timeout.
    """
    session = requests.Session()

    # Define the retry strategy
    retry_strategy = Retry(
        total=MAX_RETRIES,
        read=MAX_RETRIES,
        connect=MAX_RETRIES,
        backoff_factor=BACKOFF_FACTOR,
        status_forcelist=[408, 429, 500, 502, 503, 504], # HTTP status codes to retry on (e.g., Request Timeout, Too Many Requests, Server Errors)
        allowed_methods=["HEAD", "GET", "POST", "PUT", "DELETE", "OPTIONS", "TRACE"], # Methods to retry
        raise_on_status=False # Don't raise for status on retries, let the main request handle it after all retries
    )

    # Mount the adapter to apply retry strategy to both HTTP and HTTPS requests
    adapter = HTTPAdapter(max_retries=retry_strategy)
    session.mount("http://", adapter)
    session.mount("https://", adapter)

    payload = {"username": username, "password": password}
    attempt = 0

    while attempt <= MAX_RETRIES:
        try:
            print(f"Attempting login to {LOGIN_URL} (Attempt {attempt + 1}/{MAX_RETRIES + 1}) with timeout {INITIAL_TIMEOUT_SECONDS}s...")
            response = session.post(
                LOGIN_URL,
                json=payload,
                timeout=INITIAL_TIMEOUT_SECONDS # Apply the initial timeout to each request attempt
            )
            response.raise_for_status() # Raise HTTPError for bad responses (4xx or 5xx)

            print("Login successful.")
            return response.json()

        except requests.exceptions.Timeout:
            print(f"Attempt {attempt + 1}: Login request timed out.")
        except requests.exceptions.ConnectionError as e:
            print(f"Attempt {attempt + 1}: Connection error during login: {e}")
        except requests.exceptions.HTTPError as e:
            print(f"Attempt {attempt + 1}: HTTP error during login: {e.response.status_code} - {e.response.text}")
            if e.response.status_code not in retry_strategy.status_forcelist:
                # If it's a non-retriable HTTP error, break the loop
                print(f"Non-retriable HTTP error encountered: {e.response.status_code}.")
                return None
        except requests.exceptions.RequestException as e:
            print(f"Attempt {attempt + 1}: An unexpected request error occurred: {e}")
            # For other unexpected RequestExceptions, we might not want to retry depending on the error type
            return None
        
        attempt += 1
        if attempt <= MAX_RETRIES:
            wait_time = BACKOFF_FACTOR * (2 ** (attempt - 1))
            print(f"Retrying in {wait_time:.1f} seconds...")
            time.sleep(wait_time)

    print(f"Login failed after {MAX_RETRIES + 1} attempts.")
    return None

if __name__ == "__main__":
    # Example usage - in a real scenario, these would come from environment variables
    # or a secure configuration management system.
    example_username = os.getenv("API_USERNAME", "default_user")
    example_password = os.getenv("API_PASSWORD", "default_pass") # NEVER hardcode passwords in production

    print(f"Attempting to log in as '{example_username}' to '{LOGIN_URL}'...")
    login_result = login(example_username, example_password)

    if login_result:
        print("\nFinal Login API response:")
        import json
        print(json.dumps(login_result, indent=2))
    else:
        print("\nLogin process failed or did not return expected data after all retries.")