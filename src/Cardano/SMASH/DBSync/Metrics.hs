{-# LANGUAGE NoImplicitPrelude #-}
{-# LANGUAGE OverloadedStrings #-}

module Cardano.SMASH.DBSync.Metrics
  ( Metrics (..)
  , makeMetrics
  , registerMetricsServer
  ) where

import           Cardano.Prelude

import           System.Metrics.Prometheus.Concurrent.RegistryT (RegistryT (..), registerGauge,
                    runRegistryT, unRegistryT)
import           System.Metrics.Prometheus.Metric.Gauge (Gauge)
import           System.Metrics.Prometheus.Http.Scrape (serveHttpTextMetricsT)


data Metrics = Metrics
  { mDbHeight :: !Gauge
  , mNodeHeight :: !Gauge
  , mQueuePre :: !Gauge
  , mQueuePost :: !Gauge
  , mQueuePostWrite :: !Gauge
  }

registerMetricsServer :: Int -> IO (Metrics, Async ())
registerMetricsServer portNumber =
  runRegistryT $ do
    metrics <- makeMetrics
    registry <- RegistryT ask
    server <- liftIO . async $ runReaderT (unRegistryT $ serveHttpTextMetricsT portNumber []) registry
    pure (metrics, server)

makeMetrics :: RegistryT IO Metrics
makeMetrics =
  Metrics
    <$> registerGauge "db_block_height" mempty
    <*> registerGauge "remote_tip_height" mempty
    <*> registerGauge "action_queue_length_pre" mempty
    <*> registerGauge "action_queue_length_post" mempty
    <*> registerGauge "action_queue_length_post_write" mempty

