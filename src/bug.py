def calculate_metrics():
    # Original: return 100 / 0 # CHAOS_INJECTED
    # Fix: Replaced the deliberate 0 denominator with 1 to prevent ZeroDivisionError.
    # A more complex fix might involve dynamic denominator or error handling based on context.
    return 100 / 1