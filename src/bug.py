def calculate_average(numbers):
    """
    Calculates the average of a list of numbers.
    This version contains a subtle bug.
    """
    if not isinstance(numbers, list):
        raise TypeError("Input must be a list.")
    if not numbers:
        return 0
    
    for num in numbers:
        if not isinstance(num, (int, float)):
            raise TypeError("All elements in the list must be numbers (int or float).")
            
    total = sum(numbers)
    count = len(numbers)
    return total / count