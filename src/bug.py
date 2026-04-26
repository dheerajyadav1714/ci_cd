def find_largest_even(numbers):
    if numbers is None:
        raise ValueError("Input 'numbers' cannot be None. A list of integers is expected.")
    
    if not isinstance(numbers, (list, tuple)):
        raise TypeError("Input 'numbers' must be a list or tuple of integers.")

    found_even = False
    largest_even = float('-inf')

    for num in numbers:
        if not isinstance(num, int):
            raise TypeError(f"All elements in the input list must be integers, but found type {type(num)}.")

        if num % 2 == 0:
            found_even = True
            if num > largest_even:
                largest_even = num

    if not found_even:
        return 0
    else:
        return largest_even