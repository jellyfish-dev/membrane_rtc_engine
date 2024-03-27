# Changelog

## 0.22.0-dev
* Update deps [#374](https://github.com/jellyfish-dev/membrane_rtc_engine/pull/374)
* Fix READMEs [#365](https://github.com/jellyfish-dev/membrane_rtc_engine/pull/365)
* Send reason when endpoint crashes. [#368](https://github.com/jellyfish-dev/membrane_rtc_engine/pull/368)
* Engine doesn't crash after handling `:subscribe` message from removed endpoint [#381](https://github.com/jellyfish-dev/membrane_rtc_engine/pull/381)

## 0.21.0
* Rename the function `is_simulcast` to `simulcast?` in order to be compliant with elixir style guide. [#349](https://github.com/jellyfish-dev/membrane_rtc_engine/pull/349)
* Engine shouldn't raise when requesting incorrect simulcast variant [#351](https://github.com/jellyfish-dev/membrane_rtc_engine/pull/351)
* Fix multiple RCs when removing tracks quickly [#358](https://github.com/jellyfish-dev/membrane_rtc_engine/pull/358)
* Add option `wait_for_keyframe_request?` to static track sender [#357](https://github.com/jellyfish-dev/membrane_rtc_engine/pull/357)

## 0.20.0
* Add finished notification and remove code related to OpenTelemetry [#340](https://github.com/jellyfish-dev/membrane_rtc_engine/pull/340)
* Notify on endpoint and track metadata updates [#354](https://github.com/jellyfish-dev/membrane_rtc_engine/pull/354)
* Add handling `:track_encoding_enabled` and `:track_encoding_disabled` notification from endpoints [#352](https://github.com/jellyfish-dev/membrane_rtc_engine/pull/352)

## 0.19.0
* Discard messages from endpoints that are not marked as ready [#339](https://github.com/jellyfish-dev/membrane_rtc_engine/pull/339)
* Extend Engine.terminate API [#337](https://github.com/jellyfish-dev/membrane_rtc_engine/pull/337)
* Update to Membrane Core 1.0 [#331](https://github.com/jellyfish-dev/membrane_rtc_engine/pull/331)
* Add `get_tracks` function in `Engine` module [#328](https://github.com/jellyfish-dev/membrane_rtc_engine/pull/328)
* Change some logs to debug [#327](https://github.com/jellyfish-dev/membrane_rtc_engine/pull/327)
* Miniscule doc fix [#333](https://github.com/jellyfish-dev/membrane_rtc_engine/pull/333)

## 0.18.0
* Modify `Track`, mix.exs and docs because of adding File Endpoint [#323](https://github.com/jellyfish-dev/membrane_rtc_engine/pull/323)

## 0.17.1
* Bump deps [#318](https://github.com/jellyfish-dev/membrane_rtc_engine/pull/318)
* Add `get_active_tracks` function in `Endpoint` module [#317](https://github.com/jellyfish-dev/membrane_rtc_engine/pull/317)

## 0.17.0
* Cleanup RTC Engine deps. Move metrics to the WebRTC Endpoint [#306](https://github.com/jellyfish-dev/membrane_rtc_engine/pull/306)
* Add `get_num_forwarded_tracks` function [#300](https://github.com/jellyfish-dev/membrane_rtc_engine/pull/300)
* Add new endpoint and track notifications [#310](https://github.com/jellyfish-dev/membrane_rtc_engine/pull/310)
* Update upgrading guide to use new repo paths [#311](https://github.com/jellyfish-dev/membrane_rtc_engine/pull/311)

## 0.16.0
* Convert RTC Engine into monorepo [#298](https://github.com/jellyfish-dev/membrane_rtc_engine/pull/298)
