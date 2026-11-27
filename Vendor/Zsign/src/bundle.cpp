#include "bundle.h"
#include "base64.h"
#include "common.h"
#include "macho.h"
#include "sys/stat.h"
#include "sys/types.h"

ZBundle::ZBundle()
{
	m_pSignAssets = NULL;
	m_pSignAsset = NULL;
	m_bForceSign = false;
	m_bWeakInject = false;
	m_bRemoveProvision = false;
	m_bEnableDocuments = false;
	m_bRemoveExtensions = false;
	m_bRemoveWatchApp = false;
	m_bRemoveUISupportedDevices = false;
}

bool ZBundle::FindAppFolder(const string& strFolder, string& strAppFolder)
{
	if (ZFile::IsPathSuffix(strFolder, ".app") || ZFile::IsPathSuffix(strFolder, ".appex")) {
		strAppFolder = strFolder;
		return true;
	}

	ZFile::EnumFolder(strFolder.c_str(), true, [&](bool bFolder, const string& strPath) {
		string strName = ZUtil::GetBaseName(strPath.c_str());
		if ("__MACOSX" == strName) {
			return true;
		}
		return false;
	}, [&](bool bFolder, const string& strPath) {
		if (bFolder) {
			if (ZFile::IsPathSuffix(strPath, ".app") || ZFile::IsPathSuffix(strPath, ".appex")) {
				strAppFolder = strPath;
				return true;
			}
		}
		return false;
	});

	return (!strAppFolder.empty());
}

bool ZBundle::GetSignFolderInfo(const string& strFolder, jvalue& jvNode, bool bGetName)
{
	string strInfoPlistData;
	string strInfoPlistPath = strFolder + "/Info.plist";
	ZFile::ReadFile(strInfoPlistPath.c_str(), strInfoPlistData);

	jvalue jvInfo;
	jvInfo.read_plist(strInfoPlistData);
	string strBundleId = jvInfo["CFBundleIdentifier"];
	string strBundleExe = jvInfo["CFBundleExecutable"];
	string strBundleVersion = jvInfo["CFBundleVersion"];
	if (strBundleId.empty() || strBundleExe.empty()) {
		return false;
	}

	string strInfoSHA1;
	string strInfoSHA256;
	ZSHA::SHABase64(strInfoPlistData, strInfoSHA1, strInfoSHA256);

	jvNode["bundle_id"] = strBundleId;
	jvNode["bundle_version"] = strBundleVersion;
	jvNode["bundle_executable"] = strBundleExe;
	jvNode["sha1"] = strInfoSHA1;
	jvNode["sha256"] = strInfoSHA256;
	if (!jvNode.has("path")) {
		jvNode["path"] = strFolder.substr(m_strAppFolder.size() + 1);
	}

	if (bGetName) {
		string strBundleName = jvInfo["CFBundleDisplayName"];
		if (strBundleName.empty()) {
			strBundleName = jvInfo["CFBundleName"].as_cstr();
		}
		jvNode["name"] = strBundleName;
	}

	return true;
}

bool ZBundle::GetObjectsToSign(const string& strFolder, jvalue& jvInfo)
{
	vector<string> allBundles;
	
	std::function<void(const string&)> findAllBundles = [&](const string& currentPath) {
		ZFile::EnumFolder(currentPath.c_str(), false, NULL, [&](bool bFolder, const string& strPath) {
			if (bFolder) {
				if (ZFile::IsPathSuffix(strPath, ".app") ||
					ZFile::IsPathSuffix(strPath, ".appex") ||
					ZFile::IsPathSuffix(strPath, ".framework") ||
					ZFile::IsPathSuffix(strPath, ".xctest")) {
					allBundles.push_back(strPath);
					findAllBundles(strPath);
				} else {
					findAllBundles(strPath);
				}
			}
			return false;
		});
	};
	
	findAllBundles(strFolder);
	
	sort(allBundles.begin(), allBundles.end(), [](const string& a, const string& b) {
		size_t depthA = count(a.begin(), a.end(), '/');
		size_t depthB = count(b.begin(), b.end(), '/');
		// deeper paths first
		return depthA > depthB;
	});
	
	for (const string& bundlePath : allBundles) {
		jvalue jvNode;
		if (GetSignFolderInfo(bundlePath, jvNode)) {
			jvInfo["folders"].push_back(jvNode);
		}
	}
	
	// KI_TVOS_SKIP_NESTED_MACHO
	// Nested bundle executables are signed by SignNode().
	// Exclude their directories from standalone Mach-O discovery.
	auto skipNestedBundle = [&](bool bFolder, const string& path) {
		if (!bFolder) {
			return false;
		}

		return ZFile::IsPathSuffix(path, ".app") ||
			ZFile::IsPathSuffix(path, ".appex") ||
			ZFile::IsPathSuffix(path, ".framework") ||
			ZFile::IsPathSuffix(path, ".xctest");
	};

	ZFile::EnumFolder(strFolder.c_str(), true, skipNestedBundle, [&](bool bFolder, const string& strPath) {
		if (bFolder || string::npos != strPath.find(".dSYM") ||
			string::npos != strPath.find("_WatchKitStub")) {
			return false;
		}
		bool bMachO = false;
		{
			FILE* fp = NULL;
#ifdef _WIN32
			fopen_s(&fp, strPath.c_str(), "rb");
#else
			fp = fopen(strPath.c_str(), "rb");
#endif
			if (fp) {
				uint32_t magic = 0;
				if (1 == fread(&magic, sizeof(magic), 1, fp)) {
					bMachO = (magic == MH_MAGIC || magic == MH_CIGAM ||
							  magic == MH_MAGIC_64 || magic == MH_CIGAM_64 ||
							  magic == FAT_MAGIC || magic == FAT_CIGAM);
				}
				fclose(fp);
			}
		}
		if (bMachO) {
			jvInfo["files"].push_back(strPath.substr(m_strAppFolder.size() + 1));
		}
		return false;
	});
	
	return true;
}

bool ZBundle::GenerateCodeResources(const string& strFolder, jvalue& jvCodeRes)
{
	set<string> setFiles;
	ZFile::EnumFolder(strFolder.c_str(), true, NULL, [&](bool bFolder, const string& strPath) {
		if (!bFolder) {
			string strNode = strPath.substr(strFolder.size() + 1);
			ZUtil::StringReplace(strNode, "\\", "/");
			setFiles.insert(strNode);
		}
		return false;
	});

	jvalue jvInfo;
	jvInfo.read_plist_from_file("%s/Info.plist", strFolder.c_str());
	string strBundleExe = jvInfo["CFBundleExecutable"];

#ifdef _WIN32
	iconv ic;
	strBundleExe = ic.U82A(strBundleExe);
#endif

	setFiles.erase("_CodeSignature/CodeResources");
	setFiles.erase(strBundleExe);
	
	jvCodeRes.clear();
	jvCodeRes["files"] = jvalue(jvalue::E_OBJECT);
	jvCodeRes["files2"] = jvalue(jvalue::E_OBJECT);

	for (string strKey : setFiles) {
		if (m_bRemoveProvision && strKey == "embedded.mobileprovision") {
			string strProvFile = strFolder + "/embedded.mobileprovision";
			remove(strProvFile.c_str());
			ZLog::Print(">>> Removed embedded.mobileprovision\n");
			continue;
		}

		string strFile = strFolder + "/" + strKey;
		string strSHA1Base64;
		string strSHA256Base64;
		ZSHA::SHABase64File(strFile.c_str(), strSHA1Base64, strSHA256Base64);

#ifdef _WIN32
		strKey = ic.A2U8(strKey);
#endif

		bool bomit1 = false;
		bool bomit2 = false;

		if (ZFile::IsPathSuffix(strKey, ".lproj/locversion.plist")) {
			bomit1 = true;
			bomit2 = true;
		}

		if (ZFile::IsPathSuffix(strKey, ".DS_Store") || "Info.plist" == strKey || "PkgInfo" == strKey) {
			bomit2 = true;
		}

		if (!bomit1) {
			if (string::npos != strKey.rfind(".lproj/")) {
				jvCodeRes["files"][strKey]["hash"] = "data:" + strSHA1Base64;
				jvCodeRes["files"][strKey]["optional"] = true;
			} else {
				jvCodeRes["files"][strKey] = "data:" + strSHA1Base64;
			}
		}

		if (!bomit2) {
			jvCodeRes["files2"][strKey]["hash"] = "data:" + strSHA1Base64;
			jvCodeRes["files2"][strKey]["hash2"] = "data:" + strSHA256Base64;
			if (string::npos != strKey.rfind(".lproj/")) {
				jvCodeRes["files2"][strKey]["optional"] = true;
			}
		}
	}

	jvCodeRes["rules"]["^.*"] = true;
	jvCodeRes["rules"]["^.*\\.lproj/"]["optional"] = true;
	jvCodeRes["rules"]["^.*\\.lproj/"]["weight"] = 1000.0;
	jvCodeRes["rules"]["^.*\\.lproj/locversion.plist$"]["omit"] = true;
	jvCodeRes["rules"]["^.*\\.lproj/locversion.plist$"]["weight"] = 1100.0;
	jvCodeRes["rules"]["^Base\\.lproj/"]["weight"] = 1010.0;
	jvCodeRes["rules"]["^version.plist$"] = true;

	jvCodeRes["rules2"]["^.*"] = true;
	jvCodeRes["rules2"][".*\\.dSYM($|/)"]["weight"] = 11.0;
	jvCodeRes["rules2"]["^(.*/)?\\.DS_Store$"]["omit"] = true;
	jvCodeRes["rules2"]["^(.*/)?\\.DS_Store$"]["weight"] = 2000.0;
	jvCodeRes["rules2"]["^.*\\.lproj/"]["optional"] = true;
	jvCodeRes["rules2"]["^.*\\.lproj/"]["weight"] = 1000.0;
	jvCodeRes["rules2"]["^.*\\.lproj/locversion.plist$"]["omit"] = true;
	jvCodeRes["rules2"]["^.*\\.lproj/locversion.plist$"]["weight"] = 1100.0;
	jvCodeRes["rules2"]["^Base\\.lproj/"]["weight"] = 1010.0;
	jvCodeRes["rules2"]["^Info\\.plist$"]["omit"] = true;
	jvCodeRes["rules2"]["^Info\\.plist$"]["weight"] = 20.0;
	jvCodeRes["rules2"]["^PkgInfo$"]["omit"] = true;
	jvCodeRes["rules2"]["^PkgInfo$"]["weight"] = 20.0;
	jvCodeRes["rules2"]["^embedded\\.provisionprofile$"]["weight"] = 20.0;
	jvCodeRes["rules2"]["^version\\.plist$"]["weight"] = 20.0;

	return true;
}

void ZBundle::GetChangedFiles(jvalue& jvNode, vector<string>& arrChangedFiles)
{
	if (jvNode.has("files")) {
		for (size_t i = 0; i < jvNode["files"].size(); i++) {
			arrChangedFiles.push_back(jvNode["files"][i]);
		}
	}

	if (jvNode.has("folders")) {
		for (size_t i = 0; i < jvNode["folders"].size(); i++) {
			jvalue& jvSubNode = jvNode["folders"][i];
			GetChangedFiles(jvSubNode, arrChangedFiles);
			string strPath = jvSubNode["path"];
			arrChangedFiles.push_back(strPath + "/_CodeSignature/CodeResources");
			arrChangedFiles.push_back(strPath + "/" + jvSubNode["bundle_executable"].as_string());
		}
	}
}

void ZBundle::GetNodeChangedFiles(jvalue& jvNode, bool excludeProvisioning)
{
	if (jvNode.has("folders")) {
		for (size_t i = 0; i < jvNode["folders"].size(); i++) {
			GetNodeChangedFiles(jvNode["folders"][i], excludeProvisioning);
		}
	}

	vector<string> arrChangedFiles;
	GetChangedFiles(jvNode, arrChangedFiles);
	for (size_t i = 0; i < arrChangedFiles.size(); i++) {
		jvNode["changed"].push_back(arrChangedFiles[i]);
	}
	
	if (excludeProvisioning) {
		if ("/" == jvNode["path"]) { // root
			jvNode["changed"].push_back("embedded.mobileprovision");
		}
	}
}

bool ZBundle::SignNode(jvalue& jvNode)
{
	// KI_TVOS_STANDALONE_SIGNING_IDENTITY
	// Standalone Mach-O files use the common signing identity.
	// App and extension profiles are selected separately below.
	if (m_pSignAssets) {
		if (m_pSignAssets->empty()) {
			ZLog::Error(
				">>> No signing assets available!\n"
			);
			return false;
		}

		m_pSignAsset = &m_pSignAssets->front();
	}

	if (jvNode.has("files")) {
		for (size_t i = 0; i < jvNode["files"].size(); i++) {
			string strFile = jvNode["files"][i];
			// KI_SKIP_BUNDLE_EXECUTABLES
		// Bundle-owned executables are signed by their
		// owning bundle's SignNode invocation.
		bool bundleOwnedExecutable = false;

		if (jvNode.has("folders")) {
			for (size_t j = 0; j < jvNode["folders"].size(); j++) {
				jvalue& folder = jvNode["folders"][j];

				string folderPath = folder["path"].as_cstr();
				string executable =
					folder["bundle_executable"].as_cstr();

				if (folderPath.empty() || executable.empty()) {
					continue;
				}

				string expectedPath =
					folderPath + "/" + executable;

				if (strFile == expectedPath) {
					bundleOwnedExecutable = true;
					break;
				}
			}
		}

		if (bundleOwnedExecutable) {
			ZLog::PrintV(
				">>> Skipping bundle-owned executable: %s\n",
				strFile.c_str()
			);
			continue;
		}

		ZLog::PrintV(">>> SignFile: \t%s\n", strFile.c_str());
			ZMachO macho;
			if (macho.InitV("%s/%s", m_strAppFolder.c_str(), strFile.c_str())) {
				// KI_SIGN_FAILURE_PROPAGATION
			// KI_MAIN_EXECUTABLE_BUNDLE_ID
			// Use the owning application's bundle identifier
			// when signing its standalone main executable.
			string signingBundleID;

			if (strFile == jvNode["bundle_executable"].as_cstr()) {
				signingBundleID =
					jvNode["bundle_id"].as_cstr();
			}

			if (!macho.Sign(
				m_pSignAsset,
				m_bForceSign,
				signingBundleID,
				"",
				"",
				""
			)) {
				ZLog::ErrorV(
					">>> Nested Mach-O signing failed: %s\n",
					strFile.c_str()
				);
				return false;
			}
			} else {
				ZLog::WarnV(">>> Warning: Skipping non-Mach-O file: \t%s\n", strFile.c_str());
			}
		}
	}
	
	if (jvNode.has("folders")) {
		for (size_t i = 0; i < jvNode["folders"].size(); i++) {
			if (!SignNode(jvNode["folders"][i])) {
				return false;
			}
		}
	}

	jbase64 b64;
	string strInfoSHA1;
	string strInfoSHA256;
	string strFolder = jvNode["path"];
	string strBundleId = jvNode["bundle_id"];
	string strBundleExe = jvNode["bundle_executable"];
	b64.decode(jvNode["sha1"].as_cstr(), strInfoSHA1);
	b64.decode(jvNode["sha256"].as_cstr(), strInfoSHA256);
	if (strBundleId.empty() || strBundleExe.empty() || strInfoSHA1.empty() ||
		strInfoSHA256.empty()) {
		ZLog::ErrorV(">>> Can't get BundleID or BundleExecute or Info.plist SHASum in Info.plist! %s\n", strFolder.c_str());
		return false;
	}

#ifdef _WIN32
	iconv ic;
	strBundleExe = ic.U82A(strBundleExe);
#endif

	string strBaseFolder = m_strAppFolder;
	if ("/" != strFolder) {
		strBaseFolder += "/";
		strBaseFolder += strFolder;
	}

	string strExePath = strBaseFolder + "/" + strBundleExe;
	ZLog::PrintV(">>> SignFolder: %s, (%s)\n", ("/" == strFolder) ? ZUtil::GetBaseName(m_strAppFolder.c_str()) : strFolder.c_str(), strBundleExe.c_str());

	ZMachO macho;
	if (!macho.Init(strExePath.c_str())) {
		ZLog::ErrorV(">>> Can't parse BundleExecute file! %s\n", strExePath.c_str());
#if !TARGET_OS_IOS
		return false;
#else
		return true;
#endif
	}

	bool bForceSign = m_bForceSign;
	if ("/" == strFolder) { // inject/remove dylib before CodeResources generation
		for (const string& strDylibFile : m_arrInjectDylibs) {
			if (macho.InjectDylib(m_bWeakInject, strDylibFile.c_str())) {
				bForceSign = true;
			}
		}
		if (!m_setRemoveDylibs.empty()) {
			macho.RemoveDylibs(m_setRemoveDylibs);
			for (const string& name : m_setRemoveDylibs) {
				string baseName = name;
				if (baseName.find("@executable_path/") == 0) {
					baseName = baseName.substr(17);
				}
				ZFile::RemoveFileV("%s/%s", m_strAppFolder.c_str(), baseName.c_str());
			}
			bForceSign = true;
		}
	}

	// KI_TVOS_COMPONENT_PROFILE_SELECTION
	// App and extension bundles require an exact profile.
	// Frameworks use the common signing identity without
	// embedding an application provisioning profile.
	if (m_pSignAssets) {
		const bool isRoot = (strFolder == "/");
		const bool isApp =
			isRoot || ZFile::IsPathSuffix(strFolder, ".app");
		const bool isExtension =
			ZFile::IsPathSuffix(strFolder, ".appex");
		const bool isFramework =
			ZFile::IsPathSuffix(strFolder, ".framework");

		if (isApp || isExtension) {
			ZSignAsset* matchedAsset = nullptr;

			// Prefer exact application identifier matches.
			size_t exactMatches = 0;

			for (auto& asset : *m_pSignAssets) {
				const string expectedID =
					asset.m_strTeamId + "." + strBundleId;

				if (asset.m_strApplicationId == expectedID) {
					matchedAsset = &asset;
					++exactMatches;
				}
			}

			if (exactMatches > 1) {
				ZLog::ErrorV(
					">>> Ambiguous exact profile: %s\n",
					strBundleId.c_str()
				);
				return false;
			}

			// KI_PROFILE_DIAGNOSTICS
			ZLog::PrintV(
				"KI_PROFILE_DIAG: folder=%s bundle=%s assets=%zu root=%d\\n",
				strFolder.c_str(),
				strBundleId.c_str(),
				m_pSignAssets->size(),
				isRoot ? 1 : 0
			);

			for (auto& asset : *m_pSignAssets) {
				ZLog::PrintV(
					"KI_PROFILE_DIAG: team=[%s] appID=[%s] expected=[%s]\\n",
					asset.m_strTeamId.c_str(),
					asset.m_strApplicationId.c_str(),
					(asset.m_strTeamId + "." + strBundleId).c_str()
				);
			}

			// Fall back to the longest compatible wildcard.
			if (exactMatches == 0) {
				matchedAsset = nullptr;
				size_t bestPrefixLength = 0;
				size_t wildcardMatches = 0;

				for (auto& asset : *m_pSignAssets) {
					const string teamPrefix =
						asset.m_strTeamId + ".";

					const string& profileID =
						asset.m_strApplicationId;

					if (profileID.compare(
						0, teamPrefix.size(), teamPrefix
					) != 0) {
						continue;
					}

					const string pattern =
						profileID.substr(teamPrefix.size());

					string allowedPrefix;

					if (pattern == "*") {
						allowedPrefix = "";
					} else if (
						pattern.size() > 2 &&
						pattern.compare(
							pattern.size() - 2, 2, ".*"
						) == 0
					) {
						allowedPrefix =
							pattern.substr(0, pattern.size() - 1);
					} else {
						continue;
					}

					if (strBundleId.compare(
						0, allowedPrefix.size(), allowedPrefix
					) != 0 ||
						strBundleId.size() <= allowedPrefix.size()) {
						continue;
					}

					if (wildcardMatches == 0 ||
						allowedPrefix.size() > bestPrefixLength) {
						bestPrefixLength = allowedPrefix.size();
						matchedAsset = &asset;
						wildcardMatches = 1;
					} else if (
						allowedPrefix.size() == bestPrefixLength
					) {
						++wildcardMatches;
					}
				}

				if (wildcardMatches == 0 &&
					isRoot &&
					!m_pSignAssets->empty()) {
					ZSignAsset* primaryAsset =
						&m_pSignAssets->front();
					const string teamPrefix =
						primaryAsset->m_strTeamId + ".";
					const string& profileID =
						primaryAsset->m_strApplicationId;
					if (profileID.compare(
							0, teamPrefix.size(), teamPrefix
						) == 0 &&
						profileID.size() > teamPrefix.size() &&
						profileID.find('*') == string::npos) {
						matchedAsset = primaryAsset;
						ZLog::PrintV(
							">>> Using primary explicit profile App ID %s for root bundle %s; preserving original bundle ID.\\n",
							profileID.c_str(), strBundleId.c_str()
						);
					}
				} else if (wildcardMatches != 1) {
					matchedAsset = nullptr;
				}
			}

			if (matchedAsset == nullptr) {
				ZLog::ErrorV(
					">>> Missing or ambiguous profile: %s\n",
					strBundleId.c_str()
				);
				return false;
			}

			m_pSignAsset = matchedAsset;

			if (!ZFile::WriteFileV(
				m_pSignAsset->m_strProvData,
				"%s/embedded.mobileprovision",
				strBaseFolder.c_str()
			)) {
				ZLog::ErrorV(
					">>> Cannot embed profile: %s\n",
					strBundleId.c_str()
				);
				return false;
			}
		} else if (isFramework) {
			// Frameworks use the shared signing certificate.
			// Do not embed an application profile.
			m_pSignAsset = &m_pSignAssets->front();

			const string frameworkProfile =
				strBaseFolder + "/embedded.mobileprovision";

			if (ZFile::IsFileExists(frameworkProfile.c_str())) {
				ZLog::ErrorV(
					">>> Unexpected framework profile: %s\n",
					strBundleId.c_str()
				);
				return false;
			}
		} else {
			ZLog::ErrorV(
				">>> Unsupported nested bundle: %s\n",
				strFolder.c_str()
			);
			return false;
		}
	}

	ZFile::CreateFolderV("%s/_CodeSignature", strBaseFolder.c_str());
	string strCodeResFile = strBaseFolder + "/_CodeSignature/CodeResources";

	jvalue jvCodeRes;
	if (!bForceSign) {
		jvCodeRes.read_plist_from_file(strCodeResFile.c_str());
	}

	if (bForceSign || jvCodeRes.is_null()) { // create
		if (!GenerateCodeResources(strBaseFolder, jvCodeRes)) {
			ZLog::ErrorV(">>> Create CodeResources failed! %s\n", strBaseFolder.c_str());
			return false;
		}
	} else if (jvNode.has("changed")) { // use existsed
		for (size_t i = 0; i < jvNode["changed"].size(); i++) {
			string strFile = jvNode["changed"][i].as_cstr();
			string strRealFile = m_strAppFolder + "/" + strFile;

			string strFileSHA1;
			string strFileSHA256;
			if (!ZSHA::SHABase64File(strRealFile.c_str(), strFileSHA1, strFileSHA256)) {
				ZLog::ErrorV(">>> Can't get changed file SHASum! %s", strFile.c_str());
				return false;
			}

			string strKey = strFile;
			if ("/" != strFolder) {
				strKey = strFile.substr(strFolder.size() + 1);
			}

			jvCodeRes["files"][strKey] = "data:" + strFileSHA1;
			jvCodeRes["files2"][strKey]["hash"] = "data:" + strFileSHA1;
			jvCodeRes["files2"][strKey]["hash2"] = "data:" + strFileSHA256;

			ZLog::DebugV("\t\tChanged file: %s, %s\n", strFileSHA1.c_str(), strKey.c_str());
		}
	}

	string strCodeResData;
	jvCodeRes.style_write_plist(strCodeResData);
	if (!ZFile::WriteFile(strCodeResFile.c_str(), strCodeResData)) {
		ZLog::ErrorV("\tWriting CodeResources failed! %s\n", strCodeResFile.c_str());
		return false;
	}

	if (!macho.Sign(m_pSignAsset, bForceSign, strBundleId, strInfoSHA1, strInfoSHA256, strCodeResData)) {
		return false;
	}

	return true;
}

bool ZBundle::ModifyPluginsBundleId(const string& strOldBundleId, const string& strNewBundleId)
{
	vector<string> arrFolders;
	ZFile::EnumFolder(m_strAppFolder.c_str(), true, NULL, [&](bool bFolder, const string& strPath) {
		if (bFolder) {
			if (ZFile::IsPathSuffix(strPath, ".app") || ZFile::IsPathSuffix(strPath, ".appex")) {
				arrFolders.push_back(strPath);
			}
		}
		return false;
	});

	for (const string& strFolder: arrFolders) {
		jvalue jvInfo;
		if (!jvInfo.read_plist_from_file("%s/Info.plist", strFolder.c_str())) {
			ZLog::WarnV(">>> Can't find Plugin's Info.plist! %s\n", strFolder.c_str());
			continue;
		}

		string strOldPIBundleID = jvInfo["CFBundleIdentifier"];
		string strNewPIBundleID = strOldPIBundleID;
		ZUtil::StringReplace(strNewPIBundleID, strOldBundleId, strNewBundleId);
		jvInfo["CFBundleIdentifier"] = strNewPIBundleID;
		ZLog::PrintV(">>> BundleId: \t%s -> %s, Plugin\n", strOldPIBundleID.c_str(), strNewPIBundleID.c_str());

		if (jvInfo.has("WKCompanionAppBundleIdentifier")) {
			string strOldWKCBundleID = jvInfo["WKCompanionAppBundleIdentifier"];
			string strNewWKCBundleID = strOldWKCBundleID;
			ZUtil::StringReplace(strNewWKCBundleID, strOldBundleId, strNewBundleId);
			jvInfo["WKCompanionAppBundleIdentifier"] = strNewWKCBundleID;
			ZLog::PrintV(">>> BundleId: \t%s -> %s, Plugin-WKCompanionAppBundleIdentifier\n", strOldWKCBundleID.c_str(), strNewWKCBundleID.c_str());
		}

		if (jvInfo.has("NSExtension")) {
			if (jvInfo["NSExtension"].has("NSExtensionAttributes")) {
				if (jvInfo["NSExtension"]["NSExtensionAttributes"].has("WKAppBundleIdentifier")) {
					string strOldWKBundleID = jvInfo["NSExtension"]["NSExtensionAttributes"]["WKAppBundleIdentifier"];
					string strNewWKBundleID = strOldWKBundleID;
					ZUtil::StringReplace(strNewWKBundleID, strOldBundleId, strNewBundleId);
					jvInfo["NSExtension"]["NSExtensionAttributes"]["WKAppBundleIdentifier"] = strNewWKBundleID;
					ZLog::PrintV(">>> BundleId: \t%s -> %s, NSExtension-NSExtensionAttributes-WKAppBundleIdentifier\n", strOldWKBundleID.c_str(), strNewWKBundleID.c_str());
				}
			}
		}

		jvInfo.style_write_plist_to_file("%s/Info.plist", strFolder.c_str());
	}

	return true;
}

bool ZBundle::ModifyBundleInfo(const string& strBundleId, const string& strBundleVersion, const string& strDisplayName)
{
	jvalue jvInfo;
	if (!jvInfo.read_plist_from_file("%s/Info.plist", m_strAppFolder.c_str())) {
		ZLog::ErrorV(">>> Can't find app's Info.plist! %s\n", m_strAppFolder.c_str());
		return false;
	}

	if (!strBundleId.empty()) {
		string strOldBundleId = jvInfo["CFBundleIdentifier"];
		jvInfo["CFBundleIdentifier"] = strBundleId;
		ZLog::PrintV(">>> BundleId: \t%s -> %s\n", strOldBundleId.c_str(), strBundleId.c_str());
		ModifyPluginsBundleId(strOldBundleId, strBundleId);
	}

	if (!strDisplayName.empty()) {

		string strNewDisplayName = strDisplayName;

#ifdef _WIN32
		iconv ic;
		strNewDisplayName = ic.A2U8(strDisplayName);
#endif

		string strOldDisplayName = jvInfo["CFBundleDisplayName"];
		if (strOldDisplayName.empty()) {
			strOldDisplayName = jvInfo["CFBundleName"].as_cstr();
		}

		jvInfo["CFBundleName"] = strNewDisplayName;
		jvInfo["CFBundleDisplayName"] = strNewDisplayName;

		jvalue jvInfoStrings;
		if (jvInfoStrings.read_plist_from_file("%s/zh_CN.lproj/InfoPlist.strings", m_strAppFolder.c_str())) {
			jvInfoStrings["CFBundleName"] = strNewDisplayName;
			jvInfoStrings["CFBundleDisplayName"] = strNewDisplayName;
			jvInfoStrings.style_write_plist_to_file("%s/zh_CN.lproj/InfoPlist.strings", m_strAppFolder.c_str());
		}

		jvInfoStrings.clear();
		if (jvInfoStrings.read_plist_from_file("%s/zh-Hans.lproj/InfoPlist.strings", m_strAppFolder.c_str())) {
			jvInfoStrings["CFBundleName"] = strNewDisplayName;
			jvInfoStrings["CFBundleDisplayName"] = strNewDisplayName;
			jvInfoStrings.style_write_plist_to_file("%s/zh-Hans.lproj/InfoPlist.strings", m_strAppFolder.c_str());
		}

#ifdef _WIN32
		strOldDisplayName = ic.U82A(strOldDisplayName);
		strNewDisplayName = ic.U82A(strNewDisplayName);
#endif

		ZLog::PrintV(">>> BundleName: %s -> %s\n", strOldDisplayName.c_str(), strNewDisplayName.c_str());
	}

	if (!strBundleVersion.empty()) {
		string strOldBundleVersion = jvInfo["CFBundleVersion"];
		jvInfo["CFBundleVersion"] = strBundleVersion;
		jvInfo["CFBundleShortVersionString"] = strBundleVersion;
		ZLog::PrintV(">>> BundleVersion: %s -> %s\n", strOldBundleVersion.c_str(), strBundleVersion.c_str());
	}

	jvInfo.style_write_plist_to_file("%s/Info.plist", m_strAppFolder.c_str());
	return true;
}

void ZBundle::ApplyAppModifications()
{

	if (m_bEnableDocuments) {
		jvalue jvInfo;
		jvInfo.read_plist_from_file("%s/Info.plist", m_strAppFolder.c_str());
		jvInfo["UISupportsDocumentBrowser"] = true;
		jvInfo["UIFileSharingEnabled"] = true;
		jvInfo.style_write_plist_to_file("%s/Info.plist", m_strAppFolder.c_str());
		m_bForceSign = true;
		ZLog::Print(">>> Enabled documents support\n");
	}

	if (!m_strMinVersion.empty()) {
		jvalue jvInfo;
		jvInfo.read_plist_from_file("%s/Info.plist", m_strAppFolder.c_str());
		string strOldVersion = jvInfo["MinimumOSVersion"];
		jvInfo["MinimumOSVersion"] = m_strMinVersion;
		jvInfo.style_write_plist_to_file("%s/Info.plist", m_strAppFolder.c_str());
		m_bForceSign = true;
		ZLog::PrintV(">>> MinimumOSVersion: %s -> %s\n", strOldVersion.c_str(), m_strMinVersion.c_str());
	}

	if (m_bRemoveExtensions) {
		const char* extDirs[] = {"PlugIns", "Extensions"};
		for (const char* dir : extDirs) {
			string strPath = m_strAppFolder + "/" + dir;
			if (ZFile::IsFolder(strPath.c_str())) {
				ZFile::RemoveFolder(strPath.c_str());
				ZLog::PrintV(">>> Removed %s\n", dir);
				m_bForceSign = true;
			}
		}
	}

	if (m_bRemoveWatchApp) {
		const char* watchDirs[] = {"Watch", "WatchKit", "com.apple.WatchPlaceholder"};
		for (const char* dir : watchDirs) {
			string strPath = m_strAppFolder + "/" + dir;
			if (ZFile::IsFolder(strPath.c_str())) {
				ZFile::RemoveFolder(strPath.c_str());
				ZLog::PrintV(">>> Removed %s\n", dir);
				m_bForceSign = true;
			}
		}
	}

	if (m_bRemoveUISupportedDevices) {
		jvalue jvInfo;
		jvInfo.read_plist_from_file("%s/Info.plist", m_strAppFolder.c_str());
		if (jvInfo.has("UISupportedDevices")) {
			jvInfo.erase("UISupportedDevices");
			jvInfo.style_write_plist_to_file("%s/Info.plist", m_strAppFolder.c_str());
			m_bForceSign = true;
			ZLog::Print(">>> Removed UISupportedDevices\n");
		}
	}
}

bool ZBundle::SignFolder(ZSignAsset* pSignAsset,
							const string& strFolder,
							const string& strBundleId,
							const string& strBundleVersion,
							const string& strDisplayName,
							const vector<string>& arrInjectDylibs,
							const vector<string>& arrRemoveDylibNames,
							bool bForce,
							bool bWeakInject,
							bool bEnableCache,
							bool bRemoveProvision)
{
	m_bForceSign = bForce;
	m_pSignAsset = pSignAsset;
	m_bWeakInject = bWeakInject;
	m_bRemoveProvision = bRemoveProvision;
	m_setRemoveDylibs.clear();
	for (const string& name : arrRemoveDylibNames) {
		if (name.find('/') != string::npos) {
			m_setRemoveDylibs.insert(name);
		} else {
			m_setRemoveDylibs.insert("@executable_path/" + name);
		}
	}
	if (NULL == m_pSignAsset) {
		return false;
	}

	if (!FindAppFolder(strFolder, m_strAppFolder)) {
		ZLog::ErrorV(">>> Can't find app folder! %s\n", strFolder.c_str());
		return false;
	}

	ApplyAppModifications();

	if (!strBundleId.empty() || !strDisplayName.empty() || !strBundleVersion.empty()) {
		m_bForceSign = true;
		if (!ModifyBundleInfo(strBundleId, strBundleVersion, strDisplayName)) {
			return false;
		}
	}

	// KI_PROFILE_EMBEDDING_FIX
	// Remove the profile only when explicitly requested.
	// Otherwise, embed the selected signing profile.
	if (bRemoveProvision) {
		ZFile::RemoveFileV(
			"%s/embedded.mobileprovision",
			m_strAppFolder.c_str()
		);
	// KI_TVOS_SKIP_INITIAL_ROOT_PROFILE
	} else if (
		m_pSignAssets == NULL &&
		!pSignAsset->m_strProvData.empty()
	) {
		if (!ZFile::WriteFileV(
			pSignAsset->m_strProvData,
			"%s/embedded.mobileprovision",
			m_strAppFolder.c_str()
		)) {
			ZLog::ErrorV(
				">>> Can't write embedded.mobileprovision!\n"
			);
			return false;
		}
	}

	if (!arrInjectDylibs.empty()) {
		m_bForceSign = true;
		for (const string& strDylibFile : arrInjectDylibs) {
			string strFileName = ZUtil::GetBaseName(strDylibFile.c_str());
			if (ZFile::CopyFileV(strDylibFile.c_str(), "%s/%s", m_strAppFolder.c_str(), strFileName.c_str())) {
				m_arrInjectDylibs.push_back("@executable_path/" + strFileName);
			}
		}
	}

	string strCacheName;
	ZSHA::SHA1Text(m_strAppFolder, strCacheName);
	if (!ZFile::IsFileExistsV("./.zsign_cache/%s.json", strCacheName.c_str())) {
		m_bForceSign = true;
	}

	jvalue jvRoot;
	if (m_bForceSign) {
		jvRoot["path"] = "/";
		jvRoot["root"] = m_strAppFolder;
		if (!GetSignFolderInfo(m_strAppFolder, jvRoot, true)) {
			ZLog::ErrorV(">>> Can't get BundleID, BundleVersion, or BundleExecute in Info.plist! %s\n", m_strAppFolder.c_str());
			return false;
		}
		if (!GetObjectsToSign(m_strAppFolder, jvRoot)) {
			return false;
		}
		GetNodeChangedFiles(jvRoot, bRemoveProvision);
	} else {
		jvRoot.read_from_file("./.zsign_cache/%s.json", strCacheName.c_str());
	}

	string strAppName = jvRoot["name"];

#ifdef _WIN32
	iconv ic;
	strAppName = ic.U82A(strAppName);
#endif

	ZLog::PrintV(">>> Signing: \t%s ...\n", m_strAppFolder.c_str());
	ZLog::PrintV(">>> AppName: \t%s\n", strAppName.c_str());
	ZLog::PrintV(">>> BundleId: \t%s\n", jvRoot["bundle_id"].as_cstr());
	ZLog::PrintV(">>> Version: \t%s\n", jvRoot["bundle_version"].as_cstr());
	ZLog::PrintV(">>> TeamId: \t%s\n", m_pSignAsset->m_strTeamId.c_str());
	ZLog::PrintV(">>> SubjectCN: \t%s\n", m_pSignAsset->m_strSubjectCN.c_str());
	ZLog::PrintV(">>> ReadCache: \t%s\n", m_bForceSign ? "NO" : "YES");
	ZLog::PrintV(">>> Exclude MobileProvision: \t%s\n", bRemoveProvision ? "NO" : "YES");

	if (SignNode(jvRoot)) {
		if (bEnableCache) {
			ZFile::CreateFolder("./.zsign_cache");
			jvRoot.style_write_to_file("./.zsign_cache/%s.json", strCacheName.c_str());
		}
		return true;
	}

	return false;
}

bool ZBundle::SignFolder(list<ZSignAsset>* pSignAssets,
						const string& strFolder,
						const string& strBundleId,
						const string& strBundleVersion,
						const string& strDisplayName,
						const vector<string>& arrInjectDylibs,
						const vector<string>& arrRemoveDylibNames,
						bool bForce,
						bool bWeakInject,
						bool bEnableCache,
						bool bRemoveProvision)
{
	// KI_TVOS_MULTIPROFILE_EMPTY_GUARD
	// Never dereference front() on a missing or empty asset list.
	if (pSignAssets == NULL || pSignAssets->empty()) {
		ZLog::Error(
			">>> No multi-profile signing assets available!\\n"
		);
		return false;
	}

	m_pSignAssets = pSignAssets;

	return SignFolder(
		&m_pSignAssets->front(),
		strFolder,
		strBundleId,
		strBundleVersion,
		strDisplayName,
		arrInjectDylibs,
		arrRemoveDylibNames,
		bForce,
		bWeakInject,
		bEnableCache,
		bRemoveProvision
	);
}
