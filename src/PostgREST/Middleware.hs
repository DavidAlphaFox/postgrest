{-|
Module      : PostgREST.Middleware
Description : Sets the PostgreSQL GUCs, role, search_path and pre-request function. Validates JWT.
-}
{-# OPTIONS_GHC -fno-warn-orphans #-}
{-# LANGUAGE FlexibleContexts    #-}
{-# LANGUAGE ScopedTypeVariables #-}

module PostgREST.Middleware where

import qualified Data.Aeson          as JSON
import qualified Data.HashMap.Strict as M
import           Data.Scientific     (FPFormat (..), formatScientific,
                                      isInteger)
import qualified Hasql.Transaction   as H

import Network.Wai                   (Application, Response)
import Network.Wai.Middleware.Cors   (cors)
import Network.Wai.Middleware.Gzip   (def, gzip)
import Network.Wai.Middleware.Static (only, staticPolicy)

import Crypto.JWT

import PostgREST.ApiRequest   (ApiRequest (..))
import PostgREST.Auth         (JWTAttempt (..))
import PostgREST.Config       (AppConfig (..), corsPolicy)
import PostgREST.Error        (SimpleError (JwtTokenInvalid, JwtTokenMissing),
                               errorResponseFor)
import PostgREST.QueryBuilder (setLocalQuery, setLocalSearchPathQuery)
import Protolude              hiding (head)

runWithClaims :: AppConfig -> JWTAttempt ->
                 (ApiRequest -> H.Transaction Response) ->
                 ApiRequest -> H.Transaction Response
runWithClaims conf eClaims app req =
  case eClaims of
    JWTMissingSecret      -> return . errorResponseFor $ JwtTokenMissing
    JWTInvalid JWTExpired -> return . errorResponseFor . JwtTokenInvalid $ "JWT expired"
    JWTInvalid e          -> return . errorResponseFor . JwtTokenInvalid . show $ e
    JWTClaims claims      -> do
      H.sql $ toS . mconcat $ setSearchPathSql : setRoleSql ++ claimsSql ++ [methodSql, pathSql] ++ headersSql ++ cookiesSql ++ appSettingsSql
      mapM_ H.sql customReqCheck
      app req
      where
        methodSql = setLocalQuery mempty ("request.method", toS $ iMethod req)
        pathSql = setLocalQuery mempty ("request.path", toS $ iPath req)
        headersSql = setLocalQuery "request.header." <$> iHeaders req
        cookiesSql = setLocalQuery "request.cookie." <$> iCookies req
        claimsSql = setLocalQuery "request.jwt.claim." <$> [(c,unquoted v) | (c,v) <- M.toList claimsWithRole]
        appSettingsSql = setLocalQuery mempty <$> configSettings conf
        setRoleSql = maybeToList $ (\x ->
          setLocalQuery mempty ("role", unquoted x)) <$> M.lookup "role" claimsWithRole
        setSearchPathSql = setLocalSearchPathQuery (iSchema req : configExtraSearchPath conf)
        -- role claim defaults to anon if not specified in jwt
        claimsWithRole = M.union claims (M.singleton "role" anon)
        anon = JSON.String . toS $ configAnonRole conf
        customReqCheck = (\f -> "select " <> toS f <> "();") <$> configReqCheck conf

defaultMiddle :: Application -> Application
defaultMiddle =
    gzip def
  . cors corsPolicy
  . staticPolicy (only [("favicon.ico", "static/favicon.ico")])

unquoted :: JSON.Value -> Text
unquoted (JSON.String t) = t
unquoted (JSON.Number n) =
  toS $ formatScientific Fixed (if isInteger n then Just 0 else Nothing) n
unquoted (JSON.Bool b) = show b
unquoted v = toS $ JSON.encode v
