module Derive.Kit

import Data.Vect

import Language.Reflection.Elab
import Language.Reflection.Utils

%default total

doTimes : Applicative m => (n : Nat) -> m a -> m (Vect n a)
doTimes Z x = pure []
doTimes (S k) x = [| x :: (doTimes k x) |]

||| Generate a unique name (using `gensym`) that looks like some
||| previous name, for ease of debugging code generators.
nameFrom : TTName -> Elab TTName
nameFrom (UN x) = gensym $ if length x == 0 || ("_" `isPrefixOf` x)
                             then "x"
                             else x
nameFrom (NS n ns) = nameFrom n -- throw out namespaces here, because we want to generate bound var names
nameFrom (MN x n) = gensym $ if length n == 0 || ("_" `isPrefixOf` n)
                               then "n"
                               else n
nameFrom (SN x) = gensym "SN"
nameFrom NErased = gensym "wasErased"

||| Generate holes suitable as arguments to a term of some type
argHoles : Raw -> Elab (List TTName)
argHoles (RBind n (Pi t _) body) = do n' <- nameFrom n
                                      claim n t
                                      unfocus n
                                      (n ::) <$> argHoles body
argHoles _ = return []

enumerate : List a -> List (Nat, a)
enumerate xs = enumerate' xs 0
  where enumerate' : List a -> Nat -> List (Nat, a)
        enumerate' [] _ = []
        enumerate' (x::xs) n = (n, x) :: enumerate' xs (S n)


namespace Renamers
  ||| Cause a renamer to forget a renaming
  restrict : (TTName -> Maybe TTName) -> TTName -> (TTName -> Maybe TTName)
  restrict f n n' = if n == n' then Nothing else f n'

  ||| Extend a renamer with a new renaming
  extend : (TTName -> Maybe TTName) -> TTName -> TTName -> (TTName -> Maybe TTName)
  extend f n n' n'' = if n'' == n then Just n' else f n''

  rename : TTName -> TTName -> TTName -> Maybe TTName
  rename from to = extend (const Nothing) from to

||| Alpha-convert `Raw` terms
||| @ subst a partial name substitution function
partial
alphaRaw : (subst : TTName -> Maybe TTName) -> Raw -> Raw
alphaRaw subst (Var n) with (subst n)
  alphaRaw subst (Var n) | Nothing = Var n
  alphaRaw subst (Var n) | Just n' = Var n'
alphaRaw subst (RBind n b tm) =
  let subst' = restrict subst n
      b' = map (alphaRaw subst) b
  in RBind n b' (alphaRaw subst' tm)
alphaRaw subst (RApp tm tm') = RApp (alphaRaw subst tm) (alphaRaw subst tm')
alphaRaw subst RType = RType
alphaRaw subst (RUType x) = RUType x
alphaRaw subst (RForce tm) = RForce (alphaRaw subst tm)
alphaRaw subst (RConstant c) = RConstant c

||| Grab the binders from around a term, alpha-converting to make their names unique
partial
stealBindings : Raw -> (nsubst : TTName -> Maybe TTName) -> Elab (List (TTName, Binder Raw), Raw)
stealBindings (RBind n b tm) nsubst =
  do n' <- nameFrom n
     (bindings, result) <- stealBindings tm (extend nsubst n n')
     return ((n', map (alphaRaw nsubst) b) :: bindings, result)
stealBindings tm nsubst = return ([], alphaRaw nsubst tm)

||| Get the type annotation from a binder
getBinderTy : Binder t -> t
getBinderTy (Lam t) = t
getBinderTy (Pi t _) = t
getBinderTy (Let t _) = t
getBinderTy (NLet t _) = t
getBinderTy (Hole t) = t
getBinderTy (GHole t) = t
getBinderTy (Guess t _) = t
getBinderTy (PVar t) = t
getBinderTy (PVTy t) = t

mkDecl : TTName -> List (TTName, Binder Raw) -> Raw -> TyDecl
mkDecl fn xs tm = Declare fn (map (\(n, b) => Implicit n (getBinderTy b)) xs) tm

mkApp : Raw -> List Raw -> Raw
mkApp f [] = f
mkApp f (x :: xs) = mkApp (RApp f x) xs

unApply : Raw -> (Raw, List Raw)
unApply tm = unApply' tm []
  where unApply' : Raw -> List Raw -> (Raw, List Raw)
        unApply' (RApp f x) xs = unApply' f (x::xs)
        unApply' notApp xs = (notApp, xs)

mkPairTy : Raw -> Raw -> Raw
mkPairTy a b = `((~a, ~b) : Type)

rebind : List (TTName, Binder Raw) -> Raw -> Raw
rebind [] tm = tm
rebind ((n, b) :: nbs) tm = RBind n b $ rebind nbs tm

bindPats : List (TTName, Binder Raw) -> Raw -> Raw
bindPats [] res = res
bindPats ((n, b)::bs) res = RBind n (PVar (getBinderTy b)) $ bindPats bs res

bindPatTys : List (TTName, Binder Raw) -> Raw -> Raw
bindPatTys [] res = res
bindPatTys ((n, b)::bs) res = RBind n (PVTy (getBinderTy b)) $ bindPatTys bs res


tyConArgName : TyConArg -> TTName
tyConArgName (Parameter n _) = n
tyConArgName (Index n _) = n

setTyConArgName : TyConArg -> TTName -> TyConArg
setTyConArgName (Parameter _ t) n = Parameter n t
setTyConArgName (Index _ t) n = Index n t

updateTyConArgTy : (Raw -> Raw) -> TyConArg -> TyConArg
updateTyConArgTy f (Parameter n t) = Parameter n (f t)
updateTyConArgTy f (Index n t) = Index n (f t)

namespace Tactics
  newHole : String -> Raw -> Elab TTName
  newHole hint ty = do hn <- gensym hint
                       claim hn ty
                       unfocus hn
                       return hn

  ||| A tactic for dispatching trivial goals, along with conjunctions
  ||| and disjunctions of these.
  partial
  trivial : Elab ()
  trivial = do compute
               g <- snd <$> getGoal
               case !(forgetTypes g) of
                 `((=) {A=~A} {B=~_} ~x ~_) =>
                     do apply [| (Var `{Refl}) A x |]
                        solve
                 `(() : Type) =>
                     do apply `(() : ())
                        solve
                 `(Pair ~t1 ~t2) =>
                     do fstH <- newHole "fst" t1
                        sndH <- newHole "snd" t2
                        apply `(MkPair {A=~t1} {B=~t2} ~(Var fstH) ~(Var sndH))
                        solve
                        focus fstH; trivial
                        focus sndH; trivial
                 `(Either ~a ~b) =>
                    (do lft <- newHole "left" a
                        apply `(Left {a=~a} {b=~b} ~(Var lft))
                        solve
                        focus lft; trivial) <|>
                    (do rght <- newHole "right" b
                        apply `(Right {a=~a} {b=~b} ~(Var rght))
                        solve
                        focus rght; trivial)
                 _ =>
                     fail [TermPart g, TextPart "is not trivial"]
  partial
  repeatUntilFail : Elab () -> Elab ()
  repeatUntilFail tac = do tac
                           (repeatUntilFail tac <|> return ())

  bindPat : Elab ()
  bindPat = do compute
               g <- snd <$> getGoal
               case g of
                 Bind n (PVTy _) _ => patbind n
                 _ => fail [TermPart g, TextPart "isn't looking for a pattern."]

  intro1 : Elab TTName
  intro1 = do g <- snd <$> getGoal
              case g of
                Bind n (Pi _ _) _ => do n' <- nameFrom n
                                        intro (Just n')
                                        return n'
                _ => fail [ TextPart "Can't intro1 because goal"
                          , TermPart g
                          , TextPart "isn't a function type."]

  intros : Elab (List TTName)
  intros = do g <- snd <$> getGoal
              go g
    where go : TT -> Elab (List TTName)
          go (Bind n (Pi _ _) body) = do n' <- nameFrom n
                                         intro (Just n')
                                         (n' ::) <$> go body
          go _ = return []

--TODO: move to prelude
instance (Show a, Show b) => Show (Either a b) where
  show (Left x) = "(Left " ++ show x ++ ")"
  show (Right x) = "(Right " ++ show x ++ ")"

testTriv : ((), (), (), (Either Void ()))
testTriv = %runElab trivial
