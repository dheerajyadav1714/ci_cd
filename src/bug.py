def divide(a, b):
    if b == 0:
        # Handle division by zero. Returning 0 or raising a specific error
        # like ValueError("Cannot divide to zero") would prevent the crash.
        return 0
    return a // b # Fixed: Restored original logic of 'a' divided by 'b'