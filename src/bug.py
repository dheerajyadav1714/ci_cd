def find_largest_even(numbers):
    if numbers is None:
        raise ValueError("Input 'numbers' cannot be None. A list of integers is expected.")

    if not isinstance(numbers, (list, tuple)):
        raise TypeError("Input 'numbers' must be a list or tuple of integers.")

    found_even = False
    largest_even = float('-inf') # Fix: Initialize to negative infinity to correctly handle negative even numbers

    for num in numbers:
        if not isinstance(num, int):
            raise TypeError(f"All elements in the input list must be integers, but found type {type(num)}.")

        if num % 2 == 0:
            found_even = True
            if num > largest_even:
                largest_even = num

    if not found_even:
        return 0 # Or handle this case based on business logic, e.g., raise ValueError
    else:
        return largest_even