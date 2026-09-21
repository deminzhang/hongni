package com.hongni.plugin

import androidx.core.content.FileProvider

/**
 * Distinct FileProvider subclass so the plugin's authority
 * (`${applicationId}.hongni.files`) does not collide with the base Godot
 * template's `androidx.core.content.FileProvider` authority
 * (`${applicationId}.fileprovider`) during manifest merging. Exposes the
 * plugin-internal file paths declared in res/xml/hongni_provider_paths.xml.
 */
class HongniFileProvider : FileProvider()
