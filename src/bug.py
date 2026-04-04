# Intentionally broken code for testing Autonomous Agent
def calculate_metrics():
    # The original code 'return 100 / 0' caused a ZeroDivisionError.
    # To fix this, we ensure that division by zero does not occur.
    # As the denominator is hardcoded to 0, we provide a safe return value
    # instead of performing an invalid operation. If the denominator were
    # variable, a conditional check would be used to handle the zero case.
    return 0 # Returning 0 as a default value for an undefined metric