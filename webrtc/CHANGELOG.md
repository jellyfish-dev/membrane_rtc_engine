# Changelog

## 0.8.0-dev
* Update deps [#374](https://github.com/jellyfish-dev/membrane_rtc_engine/pull/374)
* Update the use of Engine.subscribe [#381](https://github.com/jellyfish-dev/membrane_rtc_engine/pull/381)

## 0.7.0
* Rename the function `is_keyframe` to `keyframe?` and `is_deficient?` to `deficient?` in order to be compliant with elixir style guide. [#349](https://github.com/jellyfish-dev/membrane_rtc_engine/pull/349)
* Add support for trackEncodingEnabled and trackEncodingDisabled media events [#352](https://github.com/jellyfish-dev/membrane_rtc_engine/pull/352)
* Fix TrackRemoved not being sent when Engine subscription failed [#358](https://github.com/jellyfish-dev/membrane_rtc_engine/pull/358)

## 0.6.0
* Remove code related to OpenTelemetry [#340](https://github.com/jellyfish-dev/membrane_rtc_engine/pull/340)

## 0.5.0
* Update to Membrane Core 1.0 [#331](https://github.com/jellyfish-dev/membrane_rtc_engine/pull/331)
* Change some logs to debug [#327](https://github.com/jellyfish-dev/membrane_rtc_engine/pull/327)
* Update deps [#333](https://github.com/jellyfish-dev/membrane_rtc_engine/pull/333)

## 0.4.0
* Bump deps [#323](https://github.com/jellyfish-dev/membrane_rtc_engine/pull/323)

## 0.3.0
* Bump deps [#318](https://github.com/jellyfish-dev/membrane_rtc_engine/pull/318)
* Extend `connected` and `tracksAdded` media events with information about simulcast config. [#317](https://github.com/jellyfish-dev/membrane_rtc_engine/pull/317)

## 0.2.1
* Fix `endpoint_id` missing in WebRTC endpoint telemetry label [#315](https://github.com/jellyfish-dev/membrane_rtc_engine/pull/315/)

## 0.2.0
* Move metrics from the RTC Engine [#306](https://github.com/jellyfish-dev/membrane_rtc_engine/pull/306)
* Remove unused dependency `membrane_realtimer_plugin` [#300](https://github.com/jellyfish-dev/membrane_rtc_engine/pull/300/)
* Bump deps [#309](https://github.com/jellyfish-dev/membrane_rtc_engine/pull/309) [#311](https://github.com/jellyfish-dev/membrane_rtc_engine/pull/311)

## 0.1.0
* Initial release
