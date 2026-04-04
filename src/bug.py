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
    # The 'total' parameter governs the overall number of retries, including retries for connect, read, and status codes.
    retry_strategy = Retry(
        total=MAX_RETRIES,
        read=MAX_RETRIES,  # Max retries for read errors (e.g., read timeouts)
        connect=MAX_RETRIES, # Max retries for connection errors (e.g., connection timeouts, DNS errors)
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

    try:
        # The session.post call will now internally handle all retries as defined by retry_strategy
        # If all retries fail, it will raise an exception (e.g., Timeout, ConnectionError, HTTPError)
        print(f"Attempting login to {LOGIN_URL} (initial request with {INITIAL_TIMEOUT_SECONDS}s timeout, {MAX_RETRIES} internal retries available)...")
        response = session.post(
            LOGIN_URL,
            json=payload,
            timeout=INITIAL_TIMEOUT_SECONDS # Apply the timeout to each request attempt
        )
        response.raise_for_status() # Raise HTTPError for bad responses (4xx or 5xx) if not handled by retry_strategy

        print("Login successful.")
        return response.json()

    except requests.exceptions.Timeout:
        print(f"Login request timed out after {MAX_RETRIES + 1} attempts (including retries).")
    except requests.exceptions.ConnectionError as e:
        print(f"Connection error during login after {MAX_RETRIES + 1} attempts (including retries): {e}")
    except requests.exceptions.HTTPError as e:
        # This occurs if the final response after all retries is a non-2xx status code
        # or if the status code was not in status_forcelist to be retried.
        print(f"HTTP error during login after {MAX_RETRIES + 1} attempts (or non-retriable error): {e.response.status_code} - {e.response.text}")
    except requests.exceptions.RequestException as e:
        print(f"An unexpected request error occurred during login: {e}")
    
    print(f"Login failed after all attempts or due to a critical error.")
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