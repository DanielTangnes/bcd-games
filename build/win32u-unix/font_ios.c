/* iOS override for dlls/win32u/font.c.
 *
 * Wraps upstream font_init() to register built-in CJK and Latin font family
 * replacements (mapping MS Gothic, MS PGothic, MS UI Gothic, Meiryo, Yu Gothic,
 * MS Mincho, SimSun, Microsoft YaHei, PMingLiU, Gulim, and standard Windows
 * Latin fallback families Arial / Courier New / Times New Roman to the
 * seeded iOS system fonts or Tahoma), re-runs reorder_font_list() so default
 * Swiss/Modern/Roman families sort ahead of Marlett/Symbol in family_name_tree,
 * and populates CJK SystemLink entries on Tahoma/Arial/System.
 */

#define font_init font_init_upstream
#include "../../wine/dlls/win32u/font.c"
#undef font_init

static const WCHAR *ios_first_existing_family( const WCHAR * const *candidates )
{
    for ( ; *candidates; candidates++)
        if (find_family_from_any_name( *candidates )) return *candidates;
    return NULL;
}

static void ios_register_builtin_replacements(void)
{
    static const WCHAR hiragino_kaku_w3W[] = {'H','i','r','a','g','i','n','o',' ','K','a','k','u',' ','G','o','t','h','i','c',' ','P','r','o','N',' ','W','3',0};
    static const WCHAR hiragino_kakuW[]    = {'H','i','r','a','g','i','n','o',' ','K','a','k','u',' ','G','o','t','h','i','c',' ','P','r','o','N',0};
    static const WCHAR hiragino_sansW[]    = {'H','i','r','a','g','i','n','o',' ','S','a','n','s',0};
    static const WCHAR hiragino_sans_gbW[] = {'H','i','r','a','g','i','n','o',' ','S','a','n','s',' ','G','B',0};
    static const WCHAR hiragino_min_w3W[]  = {'H','i','r','a','g','i','n','o',' ','M','i','n','c','h','o',' ','P','r','o','N',' ','W','3',0};
    static const WCHAR hiragino_minW[]     = {'H','i','r','a','g','i','n','o',' ','M','i','n','c','h','o',' ','P','r','o','N',0};
    static const WCHAR pingfang_scW[]      = {'P','i','n','g','F','a','n','g',' ','S','C',0};
    static const WCHAR pingfang_tcW[]      = {'P','i','n','g','F','a','n','g',' ','T','C',0};
    static const WCHAR apple_sd_gothicW[]  = {'A','p','p','l','e',' ','S','D',' ','G','o','t','h','i','c',' ','N','e','o',0};

    static const WCHAR arialW[]            = {'A','r','i','a','l',0};
    static const WCHAR courier_newW[]      = {'C','o','u','r','i','e','r',' ','N','e','w',0};
    static const WCHAR times_new_romanW[]  = {'T','i','m','e','s',' ','N','e','w',' ','R','o','m','a','n',0};
    static const WCHAR yu_gothicW[]        = {'Y','u',' ','G','o','t','h','i','c',0};
    static const WCHAR nsimsunW[]          = {'N','S','i','m','S','u','n',0};
    static const WCHAR simheiW[]           = {'S','i','m','H','e','i',0};
    static const WCHAR ms_yaheiW[]         = {'M','i','c','r','o','s','o','f','t',' ','Y','a','H','e','i',0};
    static const WCHAR ms_yahei_uiW[]      = {'M','i','c','r','o','s','o','f','t',' ','Y','a','H','e','i',' ','U','I',0};
    static const WCHAR gulimcheW[]         = {'G','u','l','i','m','C','h','e',0};
    static const WCHAR malgun_gothicW[]    = {'M','a','l','g','u','n',' ','G','o','t','h','i','c',0};

    /* Full-width Japanese family names used by Shift-JIS games / visual novels */
    static const WCHAR jp_ms_gothicW[]     = {0xff2d,0xff33,' ',0x30b4,0x30b7,0x30c3,0x30af,0};
    static const WCHAR jp_ms_pgothicW[]    = {0xff2d,0xff33,' ',0xff30,0x30b4,0x30b7,0x30c3,0x30af,0};
    static const WCHAR jp_ms_minchoW[]     = {0xff2d,0xff33,' ',0x660e,0x671d,0};
    static const WCHAR jp_ms_pminchoW[]    = {0xff2d,0xff33,' ',0xff30,0x660e,0x671d,0};
    static const WCHAR jp_meiryoW[]        = {0x30e1,0x30a4,0x30ea,0x30aa,0};

    static const WCHAR * const gothic_candidates[] = {
        hiragino_kaku_w3W, hiragino_kakuW, hiragino_sansW, hiragino_sans_gbW, pingfang_scW, tahomaW, NULL
    };
    static const WCHAR * const mincho_candidates[] = {
        hiragino_min_w3W, hiragino_minW, hiragino_kaku_w3W, hiragino_kakuW, hiragino_sansW, pingfang_scW, tahomaW, NULL
    };
    static const WCHAR * const sc_candidates[] = {
        pingfang_scW, hiragino_sans_gbW, hiragino_kaku_w3W, hiragino_sansW, tahomaW, NULL
    };
    static const WCHAR * const tc_candidates[] = {
        pingfang_tcW, pingfang_scW, hiragino_kaku_w3W, hiragino_sansW, tahomaW, NULL
    };
    static const WCHAR * const kr_candidates[] = {
        apple_sd_gothicW, hiragino_kaku_w3W, hiragino_sansW, pingfang_scW, tahomaW, NULL
    };
    static const WCHAR * const latin_candidates[] = {
        arialW, tahomaW, NULL
    };

    const WCHAR *gothic = ios_first_existing_family( gothic_candidates );
    const WCHAR *mincho = ios_first_existing_family( mincho_candidates );
    const WCHAR *sc     = ios_first_existing_family( sc_candidates );
    const WCHAR *tc     = ios_first_existing_family( tc_candidates );
    const WCHAR *kr     = ios_first_existing_family( kr_candidates );
    const WCHAR *latin  = ios_first_existing_family( latin_candidates );

    static const WCHAR * const gothic_targets[] = {
        ms_gothicW, ms_p_gothicW, ms_ui_gothicW, meiryoW, meiryo_uiW,
        yu_gothicW, yu_gothic_uiW, jp_ms_gothicW, jp_ms_pgothicW, jp_meiryoW, NULL
    };
    static const WCHAR * const mincho_targets[] = {
        ms_minchoW, ms_p_minchoW, jp_ms_minchoW, jp_ms_pminchoW, NULL
    };
    static const WCHAR * const sc_targets[] = {
        sim_sunW, nsimsunW, simheiW, ms_yaheiW, ms_yahei_uiW, NULL
    };
    static const WCHAR * const tc_targets[] = {
        ming_li_uW, p_ming_li_uW, microsoft_jheng_heiW, microsoft_jheng_hei_uiW, NULL
    };
    static const WCHAR * const kr_targets[] = {
        gulimW, gulimcheW, batangW, malgun_gothicW, NULL
    };
    static const WCHAR * const latin_targets[] = {
        arialW, courier_newW, times_new_romanW, NULL
    };

    const struct { const WCHAR * const *names; const WCHAR *src; } groups[] = {
        { gothic_targets, gothic },
        { mincho_targets, mincho },
        { sc_targets,     sc },
        { tc_targets,     tc },
        { kr_targets,     kr },
        { latin_targets,  latin },
    };

    for (unsigned int g = 0; g < ARRAY_SIZE(groups); g++)
    {
        const WCHAR *src = groups[g].src;
        if (!src) continue;
        for (const WCHAR * const *p = groups[g].names; *p; p++)
        {
            if (!find_family_from_any_name( *p ))
                add_family_replacement( *p, src );
            add_gdi_font_subst( *p, -1, src, -1 );
        }
    }

    /* Re-run reorder_font_list() now that Arial / Courier New / Times New Roman
     * exist in family_name_tree, so they sort at prio 0/1/2 ahead of Marlett. */
    reorder_font_list();

    /* Link the CJK replacement into Tahoma / Arial / System so fallback glyph
     * lookup succeeds even when a game draws CJK text with Tahoma or Arial. */
    if (gothic)
    {
        struct gdi_font_family *cjk_fam = find_family_from_any_name( gothic );
        const struct list *faces = cjk_fam ? get_family_face_list( cjk_fam ) : NULL;
        if (faces && !list_empty( faces ))
        {
            const struct gdi_font_face *cjk_face = LIST_ENTRY( list_head( faces ), const struct gdi_font_face, entry );
            static const WCHAR systemW[] = {'S','y','s','t','e','m',0};
            const WCHAR * const bases[] = { tahomaW, arialW, microsoft_sans_serifW, lucida_sans_unicodeW, systemW, NULL };
            for (const WCHAR * const *b = bases; *b; b++)
            {
                struct gdi_font_link *link = add_gdi_font_link( *b );
                if (link) add_gdi_font_link_entry( link, cjk_fam->family_name, cjk_face->fs );
            }
        }
    }
}

UINT font_init(void)
{
    UINT dpi = font_init_upstream();
    if (font_funcs)
    {
        pthread_mutex_lock( &font_lock );
        ios_register_builtin_replacements();
        pthread_mutex_unlock( &font_lock );
    }
    return dpi;
}
