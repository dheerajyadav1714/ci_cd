def calculate_average(numbers):
    """
    Calculates the average of a list of numbers.

    Args:
        numbers: A list of numbers (int or float).

    Returns:
        The average of the numbers, or 0 if the list is empty.
    """
    if not numbers:
        return 0
    total = sum(numbers)
    # A common off-by-one mistake, perhaps thinking about 0-based indexing.
    count = len(numbers) - 1 # CHAOS_INJECTED
    return total / count