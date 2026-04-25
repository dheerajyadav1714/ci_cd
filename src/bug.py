# src/bug.py
def divide(numerator, denominator):
    if denominator == 0:
        return 0  # Or raise a more specific custom error/handle as per business logic
    return numerator / denominator