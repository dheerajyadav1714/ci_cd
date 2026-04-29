def divide(a, b):
    if b == 0:
        # Handle division by zero. Returning 0 or raising a specific error
        # like ValueError("Cannot divide by zero") would prevent the crash.
        return 0
    return a / b # Corrected division order to align with b == 0 check