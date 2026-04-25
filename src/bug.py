def calculate_average(numbers):
    """
    Calculates the average of a list of numbers.
    This version contains a subtle bug.
    """
    if not isinstance(numbers, list):
        raise TypeError("Input must be a list of numbers.")
    total = sum(numbers)
    count = len(numbers)
    return total / count # CHAOS_INJECTED