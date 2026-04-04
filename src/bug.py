import time
import collections
import random

# Use a collections.deque with a maxlen to prevent indefinite growth
# This keeps a history of the last N transactions in memory.
# Adjust TRANSACTION_HISTORY_MAX_SIZE based on your monitoring/reporting needs
# and available memory. If a full history is required, it should be stored
# in a persistent database, not in memory.
TRANSACTION_HISTORY_MAX_SIZE = 1000
transaction_history = collections.deque(maxlen=TRANSACTION_HISTORY_MAX_SIZE)

class PaymentError(Exception):
    """Custom exception for payment processing failures."""
    pass

def process_payment(payment_data: dict) -> dict:
    """
    Simulates processing a payment.
    In a real service, this would interact with payment gateways, databases, etc.
    """
    print(f"Attempting to process payment: {payment_data.get('id')}...")
    
    # Simulate network latency and processing time
    time.sleep(random.uniform(0.01, 0.1))

    # Simulate potential errors
    if random.random() < 0.05: # 5% chance of failure
        raise PaymentError(f"Payment {payment_data.get('id')} failed due to a simulated gateway error.")

    # Simulate successful processing
    result = {
        "id": payment_data.get('id'),
        "amount": payment_data.get('amount'),
        "currency": payment_data.get('currency'),
        "status": "completed",
        "timestamp": time.time()
    }
    
    # Add the transaction result to the bounded history
    # Oldest items are automatically removed when maxlen is reached
    transaction_history.append(result)
    print(f"Payment {payment_data.get('id')} completed. Current history size: {len(transaction_history)}")
    
    # In a real payment service, the result would typically be persisted
    # to a database (e.g., PostgreSQL, MySQL) at this point.
    # The in-memory history is usually for recent monitoring or quick lookups.

    return result

if __name__ == "__main__":
    print("Payment service started. Monitoring for incoming payments...")
    payment_id_counter = 0
    try:
        while True:
            # Simulate receiving a new payment request
            payment_id_counter += 1
            payment_data = {
                "id": f"txn_{payment_id_counter:07d}",
                "amount": round(random.uniform(10.0, 1000.0), 2),
                "currency": "USD"
            }
            
            try:
                process_payment(payment_data)
            except PaymentError as e:
                print(f"Error: {e}")
            except Exception as e:
                # Catch any other unexpected errors during processing
                print(f"An unexpected error occurred during processing: {e}")

            # Simulate polling or waiting for the next payment request
            time.sleep(random.uniform(0.1, 0.5))

            # Optional: Periodically print service status
            if payment_id_counter % 100 == 0:
                print(f"\n--- Service Status ---")
                print(f"Total payments simulated: {payment_id_counter}")
                print(f"Transaction history (in-memory) size: {len(transaction_history)} (max: {TRANSACTION_HISTORY_MAX_SIZE})")
                print(f"--- End Status ---\n")

    except KeyboardInterrupt:
        print("\nPayment service stopping gracefully...")
    except Exception as e:
        print(f"\nAn unhandled error caused the service to terminate: {e}")
    finally:
        print("Service gracefully shut down.")