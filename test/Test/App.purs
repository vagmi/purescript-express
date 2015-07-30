module Test.App (testSuite) where

import Control.Monad.Eff
import Control.Monad.Eff.Class
import Control.Monad.Eff.Exception
import Data.Array (zip, zipWith, foldM, length)
import Data.Foreign.Class
import Data.Foreign.Null
import Data.Foreign.Undefined
import Data.Function
import Data.Maybe
import Data.Tuple
import Node.Express.Types
import Node.Express.Internal.App
import Prelude
import Test.Unit
import Test.Unit.Console
import Unsafe.Coerce

type FnCall = { name :: String, arguments :: Array String }

fnCall :: String -> Array String -> FnCall
fnCall name args = { name: name, arguments: args }

foreign import putCall :: Fn2 Application FnCall Unit
foreign import getCalls :: Fn1 Application (Array FnCall)
foreign import clearCalls :: Fn1 Application Unit

foreign import createMockApp :: Fn0 Application
foreign import createMockMiddleware :: Fn1 Application (Fn3 Request Response (ExpressM Unit) (ExpressM Unit))

type TestExpress e a = Eff ( express :: Express, testOutput :: TestOutput | e ) a
type AssertionExpress e = Assertion ( express :: Express, testOutput :: TestOutput | e)

toString :: forall a. a -> String
toString = unsafeCoerce

assertMatch :: forall a e. (Show a, Eq a) => String -> a -> a -> Assertion e
assertMatch what expected actual = do
    let errorMessage = what ++ " mismatch: Expected [ " ++ show expected ++ " ], Got [ " ++ show actual ++ " ]"
    assert errorMessage (expected == actual)

assertProperty ::
    forall a e. (Show a, Eq a, IsForeign a) =>
    Application -> String -> Maybe a -> AssertionExpress e
assertProperty mockApp property expected = do
    actual <- liftEff $ intlAppGetProp mockApp property
    assertMatch "Property" expected actual

assertCalls :: forall e. Application -> Array FnCall -> Assertion e
assertCalls mockApp expectedCalls = do
    let actualCalls = runFn1 getCalls mockApp
    assertMatch "Calls size" (length expectedCalls) (length actualCalls)
    foldM assertCallsAreEqual unit (zip actualCalls expectedCalls)
  where
    assertCallsAreEqual :: forall e. Unit -> Tuple FnCall FnCall -> Assertion e
    assertCallsAreEqual _ (Tuple actual expected) = do
        assertMatch "Call name" expected.name actual.name
        -- TODO: compare arguments

genHandler :: Application -> Request -> Response -> ExpressM Unit -> ExpressM Unit
genHandler mockApp req resp next =
    return $ runFn2 putCall mockApp $
        fnCall "handler" [toString req, toString resp, toString next]

genErrorHandler :: Application -> Error -> Request -> Response -> ExpressM Unit -> ExpressM Unit
genErrorHandler mockApp err req resp next =
    return $ runFn2 putCall mockApp $
        fnCall "handler" [toString err, toString req, toString resp, toString next]

testBindHttp :: forall e. Application -> Method -> String -> AssertionExpress e
testBindHttp mockApp method route = do
    return $ runFn1 clearCalls mockApp
    liftEff $ intlAppHttp mockApp (show method) route (genHandler mockApp)
    assertCalls mockApp [
        fnCall (show method) [route],
        fnCall "handler" ["request", "response", "next"]
    ]

testSuite = do
    let mockApp = runFn0 createMockApp
    test "Internal.App.getProperty" do
        assertProperty mockApp "stringProperty" (Just "string")
        -- Uncomment when there is IsForeign Int instance
        -- assertProperty mockApp "intProperty" (Just 42)
        assertProperty mockApp "floatProperty" (Just 100.1)
        assertProperty mockApp "booleanProperty" (Just true)
        assertProperty mockApp "booleanFalseProperty" (Just false)
        assertProperty mockApp "arrayProperty" (Just ["a", "b", "c"])
        assertProperty mockApp "emptyArrayProperty" (Just [] :: Maybe (Array String))
    test "Internal.App.setProperty" do
        assertProperty mockApp "testProperty" (Nothing :: Maybe String)
        liftEff $ intlAppSetProp mockApp "testProperty" "OK"
        assertProperty mockApp "testProperty" (Just "OK")
    test "Internal.App.bindHttp" do
        testBindHttp mockApp ALL "/some/path"
        testBindHttp mockApp GET "/some/path"
        testBindHttp mockApp POST "/some/path"
        testBindHttp mockApp PUT "/some/path"
        testBindHttp mockApp DELETE "/some/path"
        testBindHttp mockApp OPTIONS "/some/path"
        testBindHttp mockApp HEAD "/some/path"
        testBindHttp mockApp TRACE "/some/path"
    test "Internal.App.useMiddleware" do
        return $ runFn1 clearCalls mockApp
        liftEff $ intlAppUse mockApp (genHandler mockApp)
        assertCalls mockApp [
            fnCall "use" [],
            fnCall "handler" ["request", "response", "next"]
        ]
    test "Internal.App.useMiddlewareOnError" do
        return $ runFn1 clearCalls mockApp
        liftEff $ intlAppUseOnError mockApp (genErrorHandler mockApp)
        assertCalls mockApp [
            fnCall "use" [],
            fnCall "handler" ["error", "request", "response", "next"]
        ]
    test "Internal.App.useExternalMiddleware" do
        return $ runFn1 clearCalls mockApp
        liftEff $ intlAppUseExternal mockApp (runFn1 createMockMiddleware mockApp)
        assertCalls mockApp [
            fnCall "use" [],
            fnCall "handler" ["request", "response", "next"]
        ]
    test "Internal.App.useMiddlewareAt" do
        let route = "/some/path"
        return $ runFn1 clearCalls mockApp
        liftEff $ intlAppUseAt mockApp route (genHandler mockApp)
        assertCalls mockApp [
            fnCall "use" [route],
            fnCall "handler" ["request", "response", "next"]
        ]

