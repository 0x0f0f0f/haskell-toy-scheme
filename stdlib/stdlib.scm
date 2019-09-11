; boolean negation
(define (not x) 
    (if x #f #t))

; check if a list is the empty list
(define (null? x) 
    (if (eqv? x '()) #t #f))

; list constructor using varargs
(define (list . objs) objs) 

; identity function 
(define (id obj) obj)

; flip a function argument order
(define (flip func)
    (lambda (x y)
        (func y x)))

; function curry-ing (partial application)
(define (curry func x)
    (lambda args
        (apply func (cons x args))))

; function composition
(define (compose f g)
    (lambda (arg)
        (f (apply g arg))))

; Simple numerical functions
(define zero? (curry = 0)) ; a number is zero
(define positive? (curry < 0)) ; a number is positive
(define negative? (curry > 0))
(define (odd? num) (= (modulo num 2) 1))
(define (even? num) (= (modulo num 2) 0))

; Catamorphisms

; foldr
(define (foldr func end l) 
    (if (null? l)
        end
        (func (car lst) (foldr func end (cdr list)))))

; foldl 
(define (foldl func accum l)
    (if (null? l)
        accum
        (foldl func (func accum (car l)) (cdr l))))

; standard naming convention
(define fold foldl)
(define reduce fold)

; sum, product, and, or
(define (sum . lst) (fold + 0 lst))
(define (product . lst) (fold * 1 lst))
(define (and . lst) (fold && #t lst))
(define (or . lst) (fold || #f lst))


; Anamorphisms
(define (unfold func init pred)
    (if (pred init)
        (cons init '())
        (cons init (unfold func (func init) pred))))

; maximum of a list of arguments
(define (max first . num-list)
    (fold (lambda (old new)
            (if (> old new) old new))
        first
        num-list))

; minimum of a list of arguments
(define (min first . num-list)
    (fold (lambda (old new)
            (if (> old new) old new))
        first
        num-list))

; list length, fold an accumulator over a list counting elements
(define (length l)
    (fold (lambda (x y)
            (+ x 1))
        0
        lst))

; map a function over a list
(define (map f l) 
    (if (null? l)
        l 
        (cons (f (car l)) (map f (cdr l)))))

; #TODO filter, mem helpers

; list reverse
(define (reverse lst)  
    (if (null? lst) 
        lst 
        (append (reverse (cdr lst)) (list (car lst)))))
