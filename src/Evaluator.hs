{-# LANGUAGE ExistentialQuantification #-}
module Evaluator where

import LispTypes
import Environment
import Evaluator.Numerical

import Data.IORef
import Data.Maybe
import Control.Monad.Except

-- |Evaluate expressions. Returns a monadic IOThrowsError value
-- In Lisp, data types for both code and data are the same
-- This means that this Evaluator returns a value of type IOThrowsError LispVal


-- The val@ notation matches against any LispVal that corresponds
-- To the specified constructor then binds it back into a LispVal
-- The result has type LispVal instead of the matched Constructor
eval :: Env -> LispVal -> IOThrowsError LispVal
eval env val@(String _)             = return val
eval env val@(Number _)             = return val
eval env val@(Float _)              = return val
eval env val@(Character _)          = return val
eval env val@(Bool _)               = return val
eval env val@(Complex _)            = return val
eval env val@(Ratio _)              = return val
eval env val@(Vector _)             = return val
eval env (List [Atom "quote", val]) = return val

-- Get a variable
eval env (Atom id) = getVar env id

-- Set a variable
eval env (List [Atom "set!", Atom var, form]) =
    eval env form >>= setVar env var

-- Define a variable
eval env (List [Atom "define", Atom var, form]) =
    eval env form >>= defineVar env var

-- Define a function
-- (define (f x y) (+ x y)) => (lamda ("x" "y") ...)
eval env (List (Atom "define" : List (Atom var : params) : body)) = 
    makeNormalFunc env params body >>= defineVar env var

-- Define a variable argument function
-- (define (func a b) c . body)
eval env (List (Atom "define" : DottedList (Atom var : params)  varargs : body)) = 
    makeVarargs varargs env params body >>= defineVar env var

-- λλλ Lambda functions! λλλ
-- (lambda (a b c) (+ a b c))
eval env (List (Atom "lambda" : List params : body)) =
    makeNormalFunc env params body 

-- (lambda (a b c . d) body)
eval env (List (Atom "lambda" : DottedList params varargs: body)) =
    makeVarargs varargs env params body

-- (lambda (a b c . d) body)
eval env (List (Atom "lambda" : varargs@(Atom _) : body)) =
    makeVarargs varargs env [] body


-- If-clause. #f is false and any other value is considered true
eval env (List [Atom "if", pred, conseq, alt]) = do 
    result <- eval env pred 
    -- Evaluate pred, if it is false eval alt, if true eval conseq
    case result of 
        Bool False -> eval env alt 
        Bool True -> eval env conseq
        badArg -> throwError $ TypeMismatch "boolean" badArg 

-- cond clause: test each one of the alts clauses and eval the first
-- which test evaluates to true, otherwise eval the 'else' clause
-- Example: (cond ((> 3 2) 'greater) ((< 3 2) 'less) (else 'equal))
-- Evaluates to the atom greater.
-- see https://schemers.org/Documents/Standards/R5RS/HTML/r5rs-Z-H-7.html#%_sec_4.2.1
eval env form@(List (Atom "cond" : clauses)) = if null clauses
    then throwError $ BadSpecialForm "No true clause in cond expression" form 
    else case head clauses of
        List [Atom "else", expr] -> eval env expr 
        -- Piggy back the evaluation of the clauses on the already
        -- Existing if clause.
        List [test, expr] -> eval env $ List [Atom "if", test, expr,
            -- If test is not true, recurse the evaluation of 
            -- cond on the remaining clauses 
            List (Atom "cond" : tail clauses)]
        _ -> throwError $ BadSpecialForm "Ill-formed clause in cond expression" form


-- case expression
-- Evaluate a key expression and iterate over ((<datum1>, ...) expr) clauses
-- To check if the key value appears at least once in the datums list.
-- If so, evaluate that clause.
-- Example: 
-- (case (* 2 3)
--   ((2 3 5 7) 'prime)
--   ((1 4 6 8 9) 'composite))             ===>  composite
eval env form@(List (Atom "case" : (key : clauses))) = if null clauses
    then throwError $ BadSpecialForm "No true clause in case expression" form
    else case head clauses of
        List (Atom "else" : exprs) -> mapM (eval env) exprs >>= liftThrows . return . last 
        List (List datums : exprs) -> do 
            keyValue <- eval env key -- Evaluate the key
            -- Iterate over datums to check for an equal one
            equality <- mapM (\x -> liftThrows (eqv [keyValue, x])) datums 
            if Bool True `elem` equality
                then mapM (eval env) exprs >>= liftThrows . return . last
                else eval env $ List (Atom "case" : key : tail clauses)
        _ -> throwError $ BadSpecialForm "Ill-formed clause in case expression" form


-- Function application clause
-- Run eval recursively over args then apply func over the resulting list
eval env (List (function : args)) = do
    func <- eval env function
    argVals <- mapM (eval env) args
    apply func argVals

-- Bad form clause
eval env badForm = throwError $ BadSpecialForm "Unrecognized special form" badForm

-- |Apply a function defined in a primitives table
-- apply func args
-- Look for func into the primitives table then return 
-- the corresponding function if found, otherwise throw an error
apply :: LispVal -> [LispVal] -> IOThrowsError LispVal
apply (PrimitiveFunc func) args = liftThrows $ func args 
apply (Func params varargs body closure) args = 
    -- Throw error if argument number is wrong
    if num params /= num args && isNothing varargs 
        then throwError $ NumArgs (num params) args
        else 
            -- Bind arguments to a new env and execute statements
            -- Zip together parameter names and already evaluated args
            -- together into a list of pairs, then create 
            -- a new environment for the function closure 
            liftIO (bindVars closure $ zip params args)
            >>= bindVarArgs varargs >>= evalBody
    where
        remainingArgs = drop (length params) args
        num = toInteger . length
        -- Map the monadic function eval env over every statement in the func body
        evalBody env = liftM last $ mapM (eval env) body
        -- Bind variable argument list to env if present
        bindVarArgs arg env = case arg of
            Just argName -> liftIO $ bindVars env [(argName, List $ remainingArgs)]
            Nothing -> return env

-- |Take an initial null environment, make name/value pairs and bind
-- primitives into the new environment
primitiveBindings :: IO Env 
primitiveBindings = nullEnv >>= flip bindVars (map makePrimitiveFunc primitives)
    where makePrimitiveFunc (var, func) = (var, PrimitiveFunc func)

-- |Primitive functions table
primitives :: [(String, [LispVal] -> ThrowsError LispVal)]
primitives = 
    numericalPrimitives ++
    -- Type testing functions
    [("symbol?", unaryOp symbolp), 
    ("number?", unaryOp numberp),
    ("float?", unaryOp floatp),
    ("string?", unaryOp stringp),
    ("char?", unaryOp charp),
    ("bool?", unaryOp boolp),
    ("ratio?", unaryOp ratiop),
    ("complex?", unaryOp complexp),
    ("list?", unaryOp listp),
    ("vector?", unaryOp vectorp),

    -- Symbol handling functions
    ("symbol->string", unaryOp symboltostring),
    ("string->symbol", unaryOp stringtosymbol),
    
    -- Numerical Boolean operators
    ("=", numBoolBinop (==)),
    ("<", numBoolBinop (<)),
    (">", numBoolBinop (>)),
    ("/=", numBoolBinop (/=)),
    (">=", numBoolBinop (>=)),
    ("<=", numBoolBinop (<=)),

    -- Boolean operators
    ("&&", boolBoolBinop (&&)),
    ("||", boolBoolBinop (||)),
    
    -- String Boolean operators
    ("string=?", strBoolBinop (==)),
    ("string?", strBoolBinop (>)),
    ("string<=?", strBoolBinop (<=)),
    ("string>=?", strBoolBinop (>=)),
    
    -- List primitives
    ("car", car),
    ("cdr", cdr),
    ("cons", cons),
    ("null?", isNull),
    ("append", append),
    ("list", listConstructor),

    -- Equivalence primitives
    ("eq?", eqv),
    ("eqv?", eqv),
    ("equal?", equal)]

-- #TODO define string operators

-- |Apply an unary operator 
unaryOp :: (LispVal -> LispVal) -> [LispVal] -> ThrowsError LispVal
unaryOp f [v] = return $ f v

-- |Type testing functions
symbolp, numberp, floatp, stringp, charp, boolp, ratiop, complexp, listp, vectorp:: LispVal -> LispVal
symbolp (Atom _)        = Bool True
symbolp _               = Bool False
numberp (Number _)      = Bool True
numberp _               = Bool False
floatp (Float _)        = Bool True
floatp _                = Bool False
stringp (String _)      = Bool True
stringp _               = Bool False
charp (Character _)     = Bool True
charp _                 = Bool False
boolp (Bool _)          = Bool True
boolp _                 = Bool False
ratiop (Ratio _)        = Bool True
ratiop _                = Bool False
complexp (Complex _)    = Bool True
complexp _              = Bool False
listp (List _)          = Bool True
listp (DottedList _ _)  = Bool True
listp _                 = Bool False
vectorp (Vector _)      = Bool True
vectorp _               = Bool False

-- |Symbol handling functions
symboltostring, stringtosymbol :: LispVal -> LispVal
symboltostring (Atom s) = String s
symboltostring _ = String ""
stringtosymbol (String s) = Atom s
stringtosymbol _ = Atom ""

-- |Unpack strings from LispVal
unpackStr :: LispVal -> ThrowsError String
unpackStr (String s) = return s
unpackStr (Number s) = return $ show s 
unpackStr (Bool s ) = return $ show s
unpackStr notString = throwError $ TypeMismatch "string" notString

-- |Unpack a Bool value from a LispVal
unpackBool :: LispVal -> ThrowsError Bool 
unpackBool (Bool b) = return b 
unpackBool notBool = throwError $ TypeMismatch "boolean" notBool
    
-- |Apply an operator to two arguments and return a Bool
-- boolBinop unpacker operator arguments
-- unpacker is used to unpack the arguments from LispVals to native types
-- op performs the boolean operation

boolBinop :: (LispVal -> ThrowsError a) -> (a -> a -> Bool) -> [LispVal] -> ThrowsError LispVal
boolBinop unpacker op args = if length args /= 2
    then throwError $ NumArgs 2 args
    else do 
        left <- unpacker $ head args
        right <- unpacker $ args !! 1
        -- Op function is used as an infix operator by wrapping it in backticks
        return $ Bool $ left `op` right 

-- | Type specific boolean operators
numBoolBinop = boolBinop unpackNum
strBoolBinop = boolBinop unpackStr
boolBoolBinop = boolBinop unpackBool


-- Equivalence primitive functions

-- |eqv checks for the equivalence of two items
eqv :: [LispVal] -> ThrowsError LispVal
eqv [Bool x, Bool y]           = return $ Bool $ x == y
eqv [Number x, Number y]       = return $ Bool $ x == y
eqv [Float x, Float y]         = return $ Bool $ x == y
eqv [Ratio x, Ratio y]         = return $ Bool $ x == y
eqv [Complex x, Complex y]     = return $ Bool $ x == y
eqv [Character x, Character y] = return $ Bool $ x == y
eqv [String x, String y]       = return $ Bool $ x == y
eqv [Atom x, Atom y]           = return $ Bool $ x == y

-- eqv clause for Dotted list builds a full list and calls itself on it
eqv [DottedList xs x, DottedList ys y]
    = eqv [List $ xs ++ [x], List $ ys ++ [y]] 

-- use the helper function eqvList using eqv to compare pair by pair
eqv [l1@(List x), l2@(List y)] = eqvList eqv [l1, l2]
eqv [_, _] = return $ Bool False 
eqv badArgList = throwError $ NumArgs 2 badArgList

-- |Helper function to check for the equivalence of a pair of items
eqvPair (j, k) = case eqv [j, k] of
    Left err -> False 
    Right (Bool val) -> val

-- |Data type that can hold any function to a LispVal into a native type
data Unpacker = forall a . Eq a => AnyUnpacker (LispVal -> ThrowsError a)

-- |Helper function that takes an Unpacker and determines if two LispVals
-- are equal before unpacking them
unpackEquals :: LispVal -> LispVal -> Unpacker -> ThrowsError Bool 
unpackEquals x y (AnyUnpacker unpacker) = do 
    unpacked1 <- unpacker x 
    unpacked2 <- unpacker y
    return $ unpacked1 == unpacked2 
    `catchError` const (return False)

-- |Check equivalence of two items with weak typing 
-- (equal? 2 "2") should return #t while (eqv? 2 "2") => #f
-- This approach uses Existential Types, a ghc extension that
-- allows for heterogenous lists subject to typeclass constraints

equal :: [LispVal] -> ThrowsError LispVal
-- use the helper function eqvList using equal to compare pair by pair
equal [l1@(List x), l2@(List y)] = eqvList equal [l1, l2]
-- eqv clause for Dotted list builds a full list and calls itself on it
equal [DottedList xs x, DottedList ys y]
    = equal [List $ xs ++ [x], List $ ys ++ [y]] 
equal [x, y] = do 
    -- Make an heterogenous list of [unpackNum, unpackStr, unpackBool]\
    -- and then map the partially applied unpackEquals over it, giving a list
    -- of Bools. We use 'or' to return true if any one of them is true.
    primitiveEquals <- liftM or $ mapM (unpackEquals x y) 
        [AnyUnpacker unpackNum, AnyUnpacker unpackStr, AnyUnpacker unpackBool]
    -- Simply test the two arguments with eqv?, since eqv? is stricter than
    -- equal? return true whenever eqv? does
    eqvEquals <- eqv [x, y]
    -- Return a disjunction of eqvEquals and primitiveEquals
    return $ Bool $ primitiveEquals || let (Bool x) = eqvEquals in x
equal badArgList = throwError $ NumArgs 2 badArgList

-- |Helper function that checks for the equivalence of items in two lists
-- accepts a function as the first argument to allow for both strong/weak equivalence
eqvList :: ([LispVal] -> ThrowsError LispVal) -> [LispVal] -> ThrowsError LispVal
eqvList eqvFunc [List x, List y] = return $ Bool $ (length x == length y)
        && all eqvPair (zip x y)


-- |car returns the head of a list
car :: [LispVal] -> ThrowsError LispVal
car [List (x:xs)] = return x
car [DottedList (x:xs) _] = return x
car [badArg] = throwError $ TypeMismatch "list" badArg
car badArgList = throwError $ NumArgs 1 badArgList

-- |cdr returns the tail of a list
cdr :: [LispVal] -> ThrowsError LispVal
cdr [List (x:xs)] = return $ List xs
cdr [DottedList (_ :xs) x] = return $ DottedList xs x
cdr [DottedList [xs] x] = return x
cdr [badArg] = throwError $ TypeMismatch "list" badArg
cdr badArgList = throwError $ NumArgs 1 badArgList

-- |cons concatenates an element to the head of a list 
cons :: [LispVal] -> ThrowsError LispVal
cons [x, List []] = return $ List [x]
cons [x, List xs] = return $ List $ x : xs
cons [x, DottedList xs xlast] = 
    return $ DottedList (x : xs) xlast 
cons [x, y] = return $ DottedList [x] y
cons badArgList = throwError $ NumArgs 2 badArgList

-- #TODO move to stdlib
-- |isNull checks if a list is equal to the empty list
isNull :: [LispVal] -> ThrowsError LispVal
isNull [List x] = return $ if null x then Bool True else Bool False
isNull [DottedList [xs] x] = return $ Bool False
isNull [badArg] = throwError $ TypeMismatch "list" badArg
isNull badArgList = throwError $ NumArgs 1 badArgList

-- #TODO move to stdlib
-- |append concatenates two strings
-- (append '(a) '(b c d))      =>  (a b c d)
append :: [LispVal] -> ThrowsError LispVal
append [List x, List y] = return $ List $ x ++ y
append [DottedList [xs] x, List y] = return $ List $[xs] ++ [x] ++ y
append [List x, DottedList [ys] y] = return $ List $ [ys] ++ [y] ++ x
append [badArg] = throwError $ TypeMismatch "list" badArg
append badArgList = throwError $ NumArgs 2 badArgList

-- #TODO move to stdlib
-- |listConstructor constructs a list from a value
listConstructor :: [LispVal] -> ThrowsError LispVal
listConstructor argList = return $ List argList