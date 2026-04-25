def calculate_average(numbers):
    """
    Calculates the average of a list of numbers.
    This version contains a subtle bug.
    """
    if not isinstance(numbers, list):
        raise TypeError("Input must be a list of numbers.")
    if not numbers: # Added check for empty list
        return 0 # Returning 0 for an empty list, or could raise ValueError
    total = sum(numbers)
    count = len(numbers)
    return total / count