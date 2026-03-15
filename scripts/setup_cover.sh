#!/usr/bin/env bash
# Download and deploy cover website (Quran Reader static files)

setup_cover() {
    log_step "Setting up cover website..."

    local COVER_DIR="${PHONX_DIR}/cover"

    # Download cover site if not present or forced update
    if [[ ! -f "${COVER_DIR}/index.html" ]] || [[ "${FORCE_UPDATE:-false}" == "true" ]]; then
        log_info "Downloading cover site..."

        local COVER_URL="${PHONX_RELEASES}/cover-site.tar.gz"
        local COVER_TMP=$(mktemp -d)

        if ! curl -fSL --progress-bar "$COVER_URL" -o "${COVER_TMP}/cover-site.tar.gz"; then
            log_warn "Failed to download cover site from releases."
            log_info "Creating minimal placeholder cover page..."

            # Fallback: create a minimal cover page so the server still works
            mkdir -p "$COVER_DIR"
            create_placeholder_cover "$COVER_DIR"
        else
            # Extract to cover directory
            mkdir -p "$COVER_DIR"
            tar xzf "${COVER_TMP}/cover-site.tar.gz" -C "$COVER_DIR" --strip-components=0 2>/dev/null || \
                tar xzf "${COVER_TMP}/cover-site.tar.gz" -C "$COVER_DIR" 2>/dev/null

            # Verify extraction
            if [[ ! -f "${COVER_DIR}/index.html" ]]; then
                # Try one level deeper (tarball might have a root directory)
                local EXTRACTED_DIR
                EXTRACTED_DIR=$(find "$COVER_DIR" -maxdepth 2 -name "index.html" -printf '%h\n' | head -1)
                if [[ -n "$EXTRACTED_DIR" ]] && [[ "$EXTRACTED_DIR" != "$COVER_DIR" ]]; then
                    mv "${EXTRACTED_DIR}"/* "$COVER_DIR"/ 2>/dev/null || true
                fi
            fi

            if [[ ! -f "${COVER_DIR}/index.html" ]]; then
                log_warn "Cover site archive did not contain index.html."
                log_info "Creating minimal placeholder cover page..."
                create_placeholder_cover "$COVER_DIR"
            else
                log_ok "Cover site deployed."
            fi
        fi

        rm -rf "$COVER_TMP"
    else
        log_info "Cover site already deployed, skipping."
    fi

    # Ensure no git traces in cover directory
    rm -rf "${COVER_DIR}/.git" "${COVER_DIR}/.gitignore" "${COVER_DIR}/.github" 2>/dev/null || true
}

create_placeholder_cover() {
    local DIR="$1"
    cat > "${DIR}/index.html" <<'COVERHTML'
<!DOCTYPE html>
<html lang="ar" dir="rtl">
<head>
    <meta charset="UTF-8">
    <meta name="viewport" content="width=device-width, initial-scale=1.0">
    <title>القرآن الكريم - Quran Reader</title>
    <style>
        * { margin: 0; padding: 0; box-sizing: border-box; }
        body {
            font-family: 'Segoe UI', Tahoma, Geneva, Verdana, sans-serif;
            background: linear-gradient(135deg, #1a5e3a 0%, #0d3320 100%);
            color: #e8d5b7;
            min-height: 100vh;
            display: flex;
            flex-direction: column;
            align-items: center;
            justify-content: center;
        }
        .container {
            text-align: center;
            padding: 3rem;
            max-width: 600px;
        }
        h1 {
            font-size: 3rem;
            margin-bottom: 1rem;
            color: #c9a94e;
            text-shadow: 0 2px 4px rgba(0,0,0,0.3);
        }
        .bismillah {
            font-size: 2rem;
            margin-bottom: 2rem;
            color: #e8d5b7;
        }
        .verse {
            font-size: 1.5rem;
            line-height: 2.2;
            margin: 2rem 0;
            padding: 1.5rem;
            border: 1px solid rgba(201,169,78,0.3);
            border-radius: 12px;
            background: rgba(255,255,255,0.05);
        }
        .reference {
            font-size: 0.9rem;
            color: #8a9e8a;
            margin-top: 1rem;
        }
        footer {
            margin-top: 3rem;
            font-size: 0.8rem;
            color: #5a6e5a;
        }
    </style>
</head>
<body>
    <div class="container">
        <div class="bismillah">بِسْمِ اللَّهِ الرَّحْمَنِ الرَّحِيمِ</div>
        <h1>القرآن الكريم</h1>
        <div class="verse">
            إِنَّا أَنزَلْنَاهُ قُرْآنًا عَرَبِيًّا لَّعَلَّكُمْ تَعْقِلُونَ
        </div>
        <div class="reference">سورة يوسف - آية ٢</div>
        <footer>Quran Reader &copy; 2024</footer>
    </div>
</body>
</html>
COVERHTML
}
