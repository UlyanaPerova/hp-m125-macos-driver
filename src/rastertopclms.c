/*
 * rastertopclms - CUPS raster filter for HP printers that speak PCLm-S
 *                 ("hbpl1" in HPLIP): HP LaserJet Pro MFP M125/M126/M127/M128
 *                 and the M129-M134 family.
 *
 * Copyright (c) 2026 The m125-pclms authors
 * SPDX-License-Identifier: MIT
 *
 * Written from scratch. PCLm is a public raster subset of PDF (Wi-Fi Alliance /
 * Mopria). The PCLm-S job-ticket layout was matched against the output of
 * HP's driver as a black-box reference for interoperability; no HP code is
 * included here.
 *
 * Pipeline per page:
 *   CUPS raster (gray / RGB, 1/8/16 bit) -> 8-bit gray strips of 64 lines
 *   -> PDF RunLength compression (in parallel on several cores)
 *   -> PCLm page objects written in order to stdout.
 *
 * Build:   cc -O2 -o rastertopclms rastertopclms.c -lcups -lpthread
 * Usage:   rastertopclms job user title copies options [file]   (CUPS filter)
 *
 * Environment (optional):
 *   PCLMS_THREADS=N   number of compression threads (1 = single-threaded)
 */

#include <cups/cups.h>
#include <cups/raster.h>

#include <errno.h>
#include <fcntl.h>
#include <pthread.h>
#include <signal.h>
#include <stdarg.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/time.h>
#include <time.h>
#include <unistd.h>

#ifdef __APPLE__
#include <pthread/qos.h>
#include <sys/sysctl.h>
#endif

#define STRIP_H        64      /* lines per strip, same as HP's hbpl1 path   */
#define MAX_THREADS    16
#define OUTBUF_SIZE    (1 << 20)

/* ------------------------------------------------------------------------ */
/* Logging (CUPS reads "LEVEL: message" lines from stderr)                   */
/* ------------------------------------------------------------------------ */

static void logmsg(const char *level, const char *fmt, ...)
{
  va_list ap;
  fprintf(stderr, "%s: rastertopclms: ", level);
  va_start(ap, fmt);
  vfprintf(stderr, fmt, ap);
  va_end(ap);
  fputc('\n', stderr);
}

/* ------------------------------------------------------------------------ */
/* Output with byte counting (needed for the PDF xref table)                 */
/* ------------------------------------------------------------------------ */

typedef struct {
  FILE     *fp;
  uint64_t  pos;          /* bytes written so far                          */
  int       error;
  uint64_t *xref;         /* offsets of objects in the order they appear   */
  int       nxref, cxref;
  int      *kids;         /* page object numbers                           */
  int       nkids, ckids;
  int       next_obj;     /* next free PDF object number                   */
} out_t;

static void out_write(out_t *o, const void *p, size_t n)
{
  if (n && fwrite(p, 1, n, o->fp) != n)
    o->error = 1;
  o->pos += n;
}

static void out_printf(out_t *o, const char *fmt, ...)
{
  char    buf[1024];
  va_list ap;
  int     n;
  va_start(ap, fmt);
  n = vsnprintf(buf, sizeof(buf), fmt, ap);
  va_end(ap);
  if (n < 0)
    return;
  if ((size_t)n >= sizeof(buf))
    n = sizeof(buf) - 1;
  out_write(o, buf, (size_t)n);
}

static int grow(void **arr, int *cap, int need, size_t elem)
{
  if (need <= *cap)
    return 0;
  int   ncap = *cap ? *cap * 2 : 256;
  while (ncap < need)
    ncap *= 2;
  void *p = realloc(*arr, (size_t)ncap * elem);
  if (!p)
    return -1;
  *arr = p;
  *cap = ncap;
  return 0;
}

/* Record that an object starts at the current position. */
static void out_mark(out_t *o)
{
  if (grow((void **)&o->xref, &o->cxref, o->nxref + 1, sizeof(uint64_t)))
  {
    o->error = 1;
    return;
  }
  o->xref[o->nxref++] = o->pos;
}

/* ------------------------------------------------------------------------ */
/* PDF RunLengthDecode encoder                                               */
/*   0..127  : copy next n+1 bytes literally                                 */
/*   129..255: repeat next byte 257-n times                                  */
/*   128     : end of data                                                   */
/* Worst case output: n + n/128 + 2 bytes.                                   */
/* ------------------------------------------------------------------------ */

static size_t rle_bound(size_t n) { return n + n / 128 + 16; }

static size_t rle_encode(const uint8_t *in, size_t n, uint8_t *out)
{
  uint8_t       *o   = out;
  const uint8_t *end = in + n;
  const uint8_t *p   = in;

  while (p < end)
  {
    /* length of the run starting at p (max 128) */
    const uint8_t *q   = p + 1;
    const uint8_t *lim = (end - p > 128) ? p + 128 : end;
    while (q < lim && *q == *p)
      q++;

    if (q - p >= 2)
    {
      *o++ = (uint8_t)(257 - (q - p));
      *o++ = *p;
      p    = q;
      continue;
    }

    /* literal: extend until two equal bytes start a run, or 128 bytes */
    const uint8_t *s = p;
    lim = (end - s > 128) ? s + 128 : end;
    p++;
    while (p < lim)
    {
      if (p + 1 < end && p[0] == p[1])
        break;
      p++;
    }
    size_t len = (size_t)(p - s);
    *o++ = (uint8_t)(len - 1);
    memcpy(o, s, len);
    o += len;
  }
  *o++ = 128;
  return (size_t)(o - out);
}

/* ------------------------------------------------------------------------ */
/* Strip work items and the thread pool                                     */
/* ------------------------------------------------------------------------ */

typedef struct {
  uint8_t *gray;      /* width * STRIP_H bytes                               */
  uint8_t *rle;       /* rle_bound(width * STRIP_H)                          */
  size_t   rle_len;
  int      lines;     /* lines in the strip image                            */
  int      white;     /* 1 if all pixels are 255                             */
} strip_t;

typedef struct {
  strip_t        *strips;
  int             count;    /* strips in current batch                      */
  int             next;     /* next strip to take                           */
  int             done;
  int             width;
  int             generation;
  int             quit;
  pthread_mutex_t mu;
  pthread_cond_t  work_cv, done_cv;
  pthread_t       th[MAX_THREADS];
  int             nthreads; /* worker threads (main thread also works)      */
} pool_t;

static int is_white(const uint8_t *p, size_t n)
{
  const uint64_t *w = (const uint64_t *)(const void *)p;
  size_t          i, nw = n / 8;
  for (i = 0; i < nw; i++)
    if (w[i] != UINT64_MAX)
      return 0;
  for (i = nw * 8; i < n; i++)
    if (p[i] != 0xFF)
      return 0;
  return 1;
}

static void compress_strip(strip_t *s, int width)
{
  size_t n = (size_t)width * (size_t)s->lines;
  s->white   = is_white(s->gray, n);
  s->rle_len = rle_encode(s->gray, n, s->rle);
}

/* Take strips from the current batch until none are left. */
static void pool_drain(pool_t *pl)
{
  for (;;)
  {
    pthread_mutex_lock(&pl->mu);
    if (pl->next >= pl->count)
    {
      pthread_mutex_unlock(&pl->mu);
      return;
    }
    int i = pl->next++;
    pthread_mutex_unlock(&pl->mu);

    compress_strip(&pl->strips[i], pl->width);

    pthread_mutex_lock(&pl->mu);
    if (++pl->done == pl->count)
      pthread_cond_broadcast(&pl->done_cv);
    pthread_mutex_unlock(&pl->mu);
  }
}

static void *pool_worker(void *arg)
{
  pool_t *pl  = arg;
  int     gen = 0;

#ifdef __APPLE__
  /* Ask for performance cores: printing is user-initiated work. */
  pthread_set_qos_class_self_np(QOS_CLASS_USER_INITIATED, 0);
#endif

  for (;;)
  {
    pthread_mutex_lock(&pl->mu);
    while (!pl->quit && pl->generation == gen)
      pthread_cond_wait(&pl->work_cv, &pl->mu);
    if (pl->quit)
    {
      pthread_mutex_unlock(&pl->mu);
      return NULL;
    }
    gen = pl->generation;
    pthread_mutex_unlock(&pl->mu);
    pool_drain(pl);
  }
}

/* Compress strips[0..count) using all threads; returns when finished. */
static void pool_run(pool_t *pl, strip_t *strips, int count, int width)
{
  if (pl->nthreads == 0 || count == 1)
  {
    for (int i = 0; i < count; i++)
      compress_strip(&strips[i], width);
    return;
  }
  pthread_mutex_lock(&pl->mu);
  pl->strips = strips;
  pl->count  = count;
  pl->next   = 0;
  pl->done   = 0;
  pl->width  = width;
  pl->generation++;
  pthread_cond_broadcast(&pl->work_cv);
  pthread_mutex_unlock(&pl->mu);

  pool_drain(pl);

  pthread_mutex_lock(&pl->mu);
  while (pl->done < pl->count)
    pthread_cond_wait(&pl->done_cv, &pl->mu);
  pthread_mutex_unlock(&pl->mu);
}

static int detect_threads(void)
{
  const char *env = getenv("PCLMS_THREADS");
  int         n   = 0;

  if (env && *env)
    n = atoi(env);
  if (n <= 0)
  {
#ifdef __APPLE__
    /* Only count performance cores; efficiency cores would slow the batch. */
    int    pc  = 0;
    size_t len = sizeof(pc);
    if (sysctlbyname("hw.perflevel0.logicalcpu", &pc, &len, NULL, 0) != 0 || pc <= 0)
      pc = (int)sysconf(_SC_NPROCESSORS_ONLN);
    n = pc;
#else
    n = (int)sysconf(_SC_NPROCESSORS_ONLN);
#endif
    if (n > 4)
      n = 4; /* RLE is memory-bound; more threads stop helping */
  }
  if (n < 1)
    n = 1;
  if (n > MAX_THREADS)
    n = MAX_THREADS;
  return n;
}

static void pool_init(pool_t *pl, int threads)
{
  sigset_t block, old;
  sigemptyset(&block);
  sigaddset(&block, SIGTERM);
  pthread_sigmask(SIG_BLOCK, &block, &old); /* threads inherit this: SIGTERM goes to main */
  memset(pl, 0, sizeof(*pl));
  pthread_mutex_init(&pl->mu, NULL);
  pthread_cond_init(&pl->work_cv, NULL);
  pthread_cond_init(&pl->done_cv, NULL);
  for (int i = 0; i < threads - 1; i++)
  {
    if (pthread_create(&pl->th[i], NULL, pool_worker, pl) != 0)
      break;
    pl->nthreads++;
  }
  pthread_sigmask(SIG_SETMASK, &old, NULL);
}

static void pool_destroy(pool_t *pl)
{
  pthread_mutex_lock(&pl->mu);
  pl->quit = 1;
  pthread_cond_broadcast(&pl->work_cv);
  pthread_mutex_unlock(&pl->mu);
  for (int i = 0; i < pl->nthreads; i++)
    pthread_join(pl->th[i], NULL);
  pthread_mutex_destroy(&pl->mu);
  pthread_cond_destroy(&pl->work_cv);
  pthread_cond_destroy(&pl->done_cv);
}

/* ------------------------------------------------------------------------ */
/* Raster line -> 8-bit gray (255 = white)                                   */
/* ------------------------------------------------------------------------ */

typedef enum { IN_GRAY8, IN_GRAY16, IN_GRAY1, IN_RGB8, IN_RGBX8, IN_RGB16 } in_fmt_t;

static int pick_format(const cups_page_header2_t *h, in_fmt_t *fmt, int *invert)
{
  *invert = 0;
  switch (h->cupsColorSpace)
  {
    case CUPS_CSPACE_K:
      *invert = 1;
      /* fall through */
    case CUPS_CSPACE_W:
    case CUPS_CSPACE_SW:
      if (h->cupsBitsPerPixel == 8)  { *fmt = IN_GRAY8;  return 0; }
      if (h->cupsBitsPerPixel == 16) { *fmt = IN_GRAY16; return 0; }
      if (h->cupsBitsPerPixel == 1)  { *fmt = IN_GRAY1;  return 0; }
      break;
    case CUPS_CSPACE_RGB:
    case CUPS_CSPACE_SRGB:
    case CUPS_CSPACE_ADOBERGB:
    case CUPS_CSPACE_RGBA:
    case CUPS_CSPACE_RGBW:
      if (h->cupsColorOrder != CUPS_ORDER_CHUNKED)
        break;
      if (h->cupsBitsPerPixel == 24 && h->cupsColorSpace != CUPS_CSPACE_RGBA &&
          h->cupsColorSpace != CUPS_CSPACE_RGBW) { *fmt = IN_RGB8; return 0; }
      if (h->cupsBitsPerPixel == 32) { *fmt = IN_RGBX8; return 0; }  /* 4th byte ignored */
      if (h->cupsBitsPerPixel == 48) { *fmt = IN_RGB16; return 0; }
      break;
    default:
      break;
  }
  return -1;
}

static inline unsigned rd16(const uint8_t *p)
{
  uint16_t v;
  memcpy(&v, p, 2);
  return v;
}

static void convert_line(const uint8_t *src, uint8_t *dst, int n, in_fmt_t fmt, int invert)
{
  int i;
  switch (fmt)
  {
    case IN_GRAY8:
      if (invert)
        for (i = 0; i < n; i++) dst[i] = (uint8_t)~src[i];
      else
        memcpy(dst, src, (size_t)n);
      break;
    case IN_GRAY16: /* cupsRasterReadPixels returns 16-bit samples in host byte order */
      for (i = 0; i < n; i++)
      {
        uint8_t v = (uint8_t)(rd16(src + 2 * i) >> 8);
        dst[i]    = invert ? (uint8_t)~v : v;
      }
      break;
    case IN_GRAY1:
      for (i = 0; i < n; i++)
      {
        int bit = (src[i >> 3] >> (7 - (i & 7))) & 1;
        dst[i]  = (uint8_t)((bit ^ invert) ? 0xFF : 0x00);
      }
      break;
    case IN_RGB8: /* Rec.601 luma, same weights HP uses */
      for (i = 0; i < n; i++, src += 3)
        dst[i] = (uint8_t)((19595u * src[0] + 38470u * src[1] + 7471u * src[2]) >> 16);
      break;
    case IN_RGBX8:
      for (i = 0; i < n; i++, src += 4)
        dst[i] = (uint8_t)((19595u * src[0] + 38470u * src[1] + 7471u * src[2]) >> 16);
      break;
    case IN_RGB16:
      for (i = 0; i < n; i++, src += 6)
        dst[i] = (uint8_t)((19595u * (rd16(src) >> 8) + 38470u * (rd16(src + 2) >> 8) +
                            7471u * (rd16(src + 4) >> 8)) >> 16);
      break;
  }
}

/* ------------------------------------------------------------------------ */
/* PCLm-S grammar                                                           */
/* ------------------------------------------------------------------------ */

typedef struct {
  int  res;               /* dpi                                            */
  int  media_w_pt, media_h_pt;
  int  media_w_px;
  int  src_w, src_h;      /* printable area in pixels                       */
  int  top, left;         /* margins in pixels                              */
  int  nstrips;
  int  top_full, top_full_lines, top_partial;
  char media_name[128];
  char media_type[64];
  char quality[64];
  int  input_bin;
} page_t;

static const char *input_bin_name(int pos)
{
  static const char *names[] = {
    "alternate", "alternate_roll", "auto_select", "bottom", "center", "disc",
    "envelope", "hagaki", "large_capacity", "left", "main_tray", "main_roll",
    "manual", "middle", "photo", "rear", "right", "side", "top", "tray_1",
    "tray_2", "tray_3", "tray_4", "tray_5", "tray_N"};
  if (pos >= 0 && pos < (int)(sizeof(names) / sizeof(names[0])))
    return names[pos];
  return "auto_select";
}

/* PWG media names for common sizes, matched by size in points (+-2pt). */
static void media_name_from_size(int w, int h, char *buf, size_t len)
{
  static const struct { int w, h; const char *name; } sizes[] = {
    {612, 792, "na_letter_8.5x11in"},   {595, 842, "iso_a4_210x297mm"},
    {612, 1008, "na_legal_8.5x14in"},   {420, 595, "iso_a5_148x210mm"},
    {298, 420, "iso_a6_105x148mm"},     {516, 729, "jis_b5_182x257mm"},
    {522, 756, "na_executive_7.25x10.5in"}, {612, 936, "na_foolscap_8.5x13in"},
    {612, 965, "na_oficio_8.5x13.4in"},   {396, 612, "na_invoice_5.5x8.5in"},
    {283, 420, "jpn_hagaki_100x148mm"}, {420, 567, "jpn_oufuku_148x200mm"},
    {279, 540, "na_monarch_3.875x7.5in"}, {312, 624, "iso_dl_110x220mm"},
    {297, 684, "na_number-10_4.125x9.5in"}, {459, 649, "iso_c5_162x229mm"},
    {499, 709, "iso_b5_176x250mm"},     {323, 459, "iso_c6_114x162mm"},
    {340, 666, "jpn_chou3_120x235mm"},  {288, 432, "na_index-4x6_4x6in"},
    {360, 504, "na_5x7_5x7in"},         {363, 516, "jis_b6_128x182mm"},
    {553, 765, "om_16k_195x270mm"},     {522, 737, "om_16k_184x260mm"},
    {558, 774, "roc_16k_7.75x10.75in"}, {283, 425, "om_small-photo_100x150mm"},
  };
  for (size_t i = 0; i < sizeof(sizes) / sizeof(sizes[0]); i++)
    if (abs(sizes[i].w - w) <= 2 && abs(sizes[i].h - h) <= 2)
    {
      snprintf(buf, len, "%s", sizes[i].name);
      return;
    }
  snprintf(buf, len, "custom_%.2fx%.2fin", w / 72.0, h / 72.0);
}

static void safe_copy(char *dst, size_t len, const char *src)
{
  size_t j = 0;
  /* keep the ticket to one line per key */
  for (size_t i = 0; src[i] && j + 1 < len; i++)
    if (src[i] >= ' ' && src[i] != 0x7F)
      dst[j++] = src[i];
  dst[j] = 0;
}

/* Reject headers that are corrupt or impossible for this printer. */
static int check_header(const cups_page_header2_t *h)
{
  unsigned bpl;
  if (h->cupsWidth == 0 || h->cupsWidth > 30000 || h->cupsHeight == 0 || h->cupsHeight > 60000)
  {
    logmsg("ERROR", "bad raster size %ux%u", h->cupsWidth, h->cupsHeight);
    return -1;
  }
  if (h->cupsBitsPerPixel == 0 || h->cupsBitsPerPixel > 64)
  {
    logmsg("ERROR", "bad bits per pixel %u", h->cupsBitsPerPixel);
    return -1;
  }
  bpl = (unsigned)(((unsigned long long)h->cupsWidth * h->cupsBitsPerPixel + 7) / 8);
  if (h->cupsBytesPerLine != bpl)
  {
    logmsg("ERROR", "bytes per line %u does not match width %u x %u bits", h->cupsBytesPerLine,
           h->cupsWidth, h->cupsBitsPerPixel);
    return -1;
  }
  /* 3000 pt = 41.7 in, far above the 14 in this printer takes */
  if (h->PageSize[0] > 3000 || h->PageSize[1] > 3000 || h->Margins[0] > 3000 || h->Margins[1] > 3000 ||
      h->ImagingBoundingBox[2] > 3000 || h->ImagingBoundingBox[3] > 3000)
  {
    logmsg("ERROR", "bad page size %ux%u pt", h->PageSize[0], h->PageSize[1]);
    return -1;
  }
  return 0;
}

static int setup_page(const cups_page_header2_t *h, page_t *pg)
{
  memset(pg, 0, sizeof(*pg));
  pg->res = (int)h->HWResolution[0];
  if (pg->res != 300 && pg->res != 600 && pg->res != 1200)
  {
    logmsg("ERROR", "unsupported resolution %d dpi", pg->res);
    return -1;
  }
  if (h->HWResolution[1] != h->HWResolution[0])
    logmsg("WARNING", "non-square resolution %ux%u", h->HWResolution[0], h->HWResolution[1]);

  int pw = (int)h->PageSize[0], ph = (int)h->PageSize[1];
  if (pw <= 0 || ph <= 0)
  {
    pw = (int)((h->cupsWidth * 72.0) / pg->res + 0.5);
    ph = (int)((h->cupsHeight * 72.0) / pg->res + 0.5);
  }
  pg->media_w_pt = pw;
  pg->media_h_pt = ph;
  pg->media_w_px = (int)(((double)pw / 72.0) * pg->res + 0.5);

  const unsigned *bb = h->ImagingBoundingBox;
  if (bb[2] > bb[0] && bb[3] > bb[1] && bb[3] <= (unsigned)ph)
  {
    pg->src_w = (int)(((bb[2] - bb[0]) * (unsigned)pg->res) / 72);
    pg->src_h = (int)(((bb[3] - bb[1]) * (unsigned)pg->res) / 72);
    pg->top   = (int)((((unsigned)ph - bb[3]) * (unsigned)pg->res) / 72);
    pg->left  = (int)((h->Margins[0] * (unsigned)pg->res) / 72);
  }
  else
  {
    pg->src_w = (int)h->cupsWidth;
    pg->src_h = (int)h->cupsHeight;
  }
  if (pg->left + pg->src_w > pg->media_w_px)
    pg->left = 0;
  if (pg->src_w > pg->media_w_px)
    pg->src_w = pg->media_w_px;
  if (pg->src_w <= 0 || pg->src_h <= 0)
  {
    logmsg("ERROR", "empty page");
    return -1;
  }

  pg->nstrips = (pg->src_h + STRIP_H - 1) / STRIP_H;

  if (pg->top > 0)
  {
    if (pg->top <= STRIP_H)
    {
      pg->top_full       = 1;
      pg->top_full_lines = pg->top;
      pg->top_partial    = 0;
    }
    else
    {
      pg->top_full       = pg->top / STRIP_H;
      pg->top_full_lines = STRIP_H;
      pg->top_partial    = pg->top - pg->top_full * STRIP_H;
    }
  }

  if (h->cupsString[0][0])
    safe_copy(pg->media_name, sizeof(pg->media_name), h->cupsString[0]);
  else if (h->cupsPageSizeName[0])
    safe_copy(pg->media_name, sizeof(pg->media_name), h->cupsPageSizeName);
  else
    media_name_from_size(pw, ph, pg->media_name, sizeof(pg->media_name));
  safe_copy(pg->media_type, sizeof(pg->media_type), h->MediaType);
  if (h->cupsInteger[2] == 1) /* EconoMode */
    snprintf(pg->quality, sizeof(pg->quality), "draft");
  else
    safe_copy(pg->quality, sizeof(pg->quality), h->OutputType);
  pg->input_bin = (int)h->MediaPosition;
  return 0;
}

static void job_start_time(char *buf, size_t len)
{
  struct timeval tv;
  struct tm      tmv;
  char           a[40];
  gettimeofday(&tv, NULL);
  time_t t = tv.tv_sec;
  localtime_r(&t, &tmv);
  strftime(a, sizeof(a), "%a %b %e %H:%M:%S", &tmv);
  snprintf(buf, len, "%s:%d %d", a, (int)(tv.tv_usec / 1000) % 1000, (tmv.tm_year + 1900) % 10000);
}

static void write_ticket(out_t *o, const page_t *pg, int job_id, const char *start_time)
{
  out_printf(o, "%%  genPCLm (Ver: %f)\n", 0.93);
  out_printf(o, "%%============= Job Ticket =============\n");
  out_printf(o, "%%  PCLmS-Job-Ticket\n");
  out_printf(o, "%%      job-ticket-version: 0.1\n");
  out_printf(o, "%%      epcl-version: 1.01\n");
  out_printf(o, "%%    JobSection\n");
  out_printf(o, "%%      job-id: %d\n", job_id);
  out_printf(o, "%%      job-start-time: %s\n", start_time);
  out_printf(o, "%%    MediaHandlingSection\n");
  out_printf(o, "%%      media-size-name: %s\n", pg->media_name);
  out_printf(o, "%%      media-type: %s\n", pg->media_type);
  out_printf(o, "%%      media-source: %s\n", input_bin_name(pg->input_bin));
  out_printf(o, "%%      sides: one-sided\n");
  out_printf(o, "%%      output-bin: top_output\n");
  out_printf(o, "%%    RenderingSection\n");
  out_printf(o, "%%      pclm-compression-method: RLE\n");
  out_printf(o, "%%      strip-height: %d\n", STRIP_H);
  out_printf(o, "%%      print-color-mode: monochrome\n");
  out_printf(o, "%%      print-rendering-intent: none\n");
  out_printf(o, "%%      print-quality: %s\n", pg->quality);
  out_printf(o, "%%      printer-resolution: %d\n", pg->res);
  out_printf(o, "%%      orientation-requested: 0\n");
  out_printf(o, "%%      copies: 1\n");
  out_printf(o, "%%      pclm-raster-back-side: xxx\n");
  out_printf(o, "%%      margins-pre-applied: TRUE\n");
  out_printf(o, "%%  PCLmS-Job-Ticket-End\n");
}

/* Appends one formatted line to a growing buffer. */
typedef struct { char *p; size_t n, cap; int err; } sbuf_t;

static void sb_printf(sbuf_t *b, const char *fmt, ...)
{
  char    tmp[256];
  va_list ap;
  va_start(ap, fmt);
  int n = vsnprintf(tmp, sizeof(tmp), fmt, ap);
  va_end(ap);
  if (n < 0 || (size_t)n >= sizeof(tmp))
  {
    b->err = 1;
    return;
  }
  if (b->n + (size_t)n + 1 > b->cap)
  {
    size_t nc = b->cap ? b->cap * 2 : 8192;
    while (nc < b->n + (size_t)n + 1)
      nc *= 2;
    char *q = realloc(b->p, nc);
    if (!q)
    {
      b->err = 1;
      return;
    }
    b->p   = q;
    b->cap = nc;
  }
  memcpy(b->p + b->n, tmp, (size_t)n);
  b->n += (size_t)n;
}

static void write_page_header(out_t *o, const page_t *pg)
{
  int page_obj = o->next_obj;
  int image    = page_obj + 2;
  int nimg     = 0;
  int ntop     = pg->top ? pg->top_full + (pg->top_partial ? 1 : 0) : 0;

  out_printf(o, "%%============= PCLm: FileBody: Object 3 - page object\n");
  out_mark(o);
  out_printf(o, "%d 0 obj\n", page_obj);
  if (!grow((void **)&o->kids, &o->ckids, o->nkids + 1, sizeof(int)))
    o->kids[o->nkids++] = page_obj;
  else
    o->error = 1;
  o->next_obj++;

  out_printf(o, "<<\n/Type /Page\n/Parent 2 0 R\n/Resources <<\n/XObject <<\n");
  for (int i = 0; i < ntop + pg->nstrips; i++, nimg++, image += 2)
    out_printf(o, "/Image%d %d 0 R\n", nimg, image);
  out_printf(o, ">>\n>>\n");
  out_printf(o, "/MediaBox [ 0 0 %d %d ]\n", pg->media_w_pt, pg->media_h_pt);
  out_printf(o, "/Contents [ %d 0 R ]\n", o->next_obj);
  out_printf(o, ">>\nendobj\n");

  /* page content stream: place each strip below the previous one */
  float  scale = (float)pg->res / 72.0f;
  int    y     = (int)((pg->media_h_pt * scale) + 0.99);
  int    idx   = 0;
  sbuf_t sb    = {0};

  out_printf(o, "%%Image Transformation Matrix: width, skewX, skewY, height, xAnchor, yAnchor\n");
  sb_printf(&sb, "%f 0 0 %f 0 0 cm\n", 72.0 / pg->res, 72.0 / pg->res);

#define PLACE(h_, y_)                                                                   \
  do {                                                                                  \
    sb_printf(&sb, "/P <</MCID 0>> BDC q\n");                                           \
    sb_printf(&sb, "%%Image Transformation Matrix: width, skewX, skewY, height, xAnchor, yAnchor\n"); \
    sb_printf(&sb, "%d 0 0 %d 0 %d cm\n", pg->media_w_px, (h_), (y_));                 \
    sb_printf(&sb, "/Image%d Do Q\n", idx++);                                           \
  } while (0)

  if (pg->top)
  {
    for (int i = 0; i < pg->top_full; i++)
    {
      y -= pg->top_full_lines;
      PLACE(pg->top_full_lines, y);
    }
    if (pg->top_partial)
    {
      y -= pg->top_partial;
      PLACE(pg->top_partial, y);
    }
  }
  for (int i = 0; i < pg->nstrips; i++)
  {
    if (i == pg->nstrips - 1)
    {
      int left_lines = pg->src_h - (pg->nstrips - 1) * STRIP_H;
      y -= left_lines;
      PLACE(left_lines, y);
    }
    else
    {
      y -= STRIP_H;
      if (y < 0)
        PLACE(STRIP_H + y, 0);
      else
        PLACE(STRIP_H, y);
    }
  }
#undef PLACE

  if (sb.err)
    o->error = 1;
  out_printf(o, "%%============= PCLm: FileBody: Page Content Stream object\n");
  out_mark(o);
  out_printf(o, "%d 0 obj\n<<\n/Length %zu\n>>\nstream\n", o->next_obj, sb.n);
  out_write(o, sb.p, sb.n);
  out_printf(o, "endstream\nendobj\n");
  o->next_obj++;
  free(sb.p);
}

static void write_strip(out_t *o, int width, int lines, const uint8_t *rle, size_t len, int white)
{
  out_printf(o, "%%============= PCLm: FileBody: Strip Stream: RLE Image \n");
  out_mark(o);
  out_printf(o, "%d 0 obj\n", o->next_obj++);
  out_printf(o, "<<\n/Width %d\n/ColorSpace /DeviceGray\n/Height %d\n/Filter /RunLengthDecode\n"
                "/Subtype /Image\n/Length %zu\n/Type /XObject\n/BitsPerComponent 8\n/Name /%s\n>>\nstream\n",
             width, lines, len, white ? "WhiteStrip" : "ColorStrip");
  out_write(o, rle, len);
  out_printf(o, "\nendstream\nendobj\n");

  out_printf(o, "%%============= PCLm: Object - Image Transformation \n");
  out_mark(o);
  out_printf(o, "%d 0 obj\n", o->next_obj++);
  out_printf(o, "<<\n/Length 14\n>>\nstream\nq /image Do Q\nendstream\nendobj\n");
}

static void write_trailer(out_t *o)
{
  out_printf(o, "%%============= PCLm: FileBody: Object 1 - Catalog\n");
  out_mark(o);
  out_printf(o, "1 0 obj\n<<\n/Type /Catalog\n/Pages 2 0 R\n>>\nendobj\n");

  out_printf(o, "%%============= PCLm: FileBody: Object 2 - page tree \n");
  out_mark(o);
  out_printf(o, "2 0 obj\n<<\n/Count %d\n/Kids [ ", o->nkids);
  for (int i = 0; i < o->nkids; i++)
    out_printf(o, "%d 0 R ", o->kids[i]);
  out_printf(o, "]\n/Type /Pages\n>>\nendobj\n");

  out_printf(o, "%%============= PCLm: cross-reference section: object 0, 6 entries\n");
  uint64_t xref_pos = o->pos;
  int      nbody    = o->nxref - 2; /* objects 3.. ; last two are 1 and 2 */

  out_printf(o, "xref\n0 1\n0000000000 65535 f\n");
  out_printf(o, "3 %d\n", nbody);
  for (int i = 0; i < nbody; i++)
    out_printf(o, "%010llu 00000 n\n", (unsigned long long)o->xref[i]);
  out_printf(o, "1 2\n");
  out_printf(o, "%010llu 00000 n\n", (unsigned long long)o->xref[nbody]);
  out_printf(o, "%010llu 00000 n\n", (unsigned long long)o->xref[nbody + 1]);
  out_printf(o, "%%============= PCLm: File Trailer\n");
  out_printf(o, "trailer\n<<\n/Size %d\n/Root 1 0 R\n>>\nstartxref\n%llu\n%%%%EOF\n",
             nbody + 3, (unsigned long long)xref_pos);
}

/* ------------------------------------------------------------------------ */
/* Main                                                                      */
/* ------------------------------------------------------------------------ */

/* Input reader that counts bytes, so a job that ends in the middle of a page header can be
 * told apart from a clean end of job (cupsRasterReadHeader2 returns 0 for both). */
typedef struct { int fd; unsigned long long total; unsigned char sync[4]; int nsync; } input_t;

static ssize_t input_read(void *ctx, unsigned char *buf, size_t len)
{
  input_t *in = ctx;
  ssize_t  n;
  do
    n = read(in->fd, buf, len);
  while (n < 0 && errno == EINTR && in->fd >= 0 && fcntl(in->fd, F_GETFD) != -1);
  if (n > 0)
  {
    for (ssize_t i = 0; i < n && in->nsync < 4; i++)
      in->sync[in->nsync++] = buf[i];
    in->total += (unsigned long long)n;
  }
  return n;
}

static volatile sig_atomic_t canceled = 0;
static volatile sig_atomic_t in_page  = 0;
static int                   input_fd = 0;

static void on_term(int sig)
{
  (void)sig;
  if (!in_page)
    _exit(1);      /* waiting for the next page: nothing to finish */
  canceled = 1;    /* mid-page: the main loop pads the page with white and ends the file */
  close(input_fd); /* wakes a read that is waiting for data (close is async-signal-safe) */
}

int main(int argc, char *argv[])
{
  int fd = 0;

  if (argc < 6 || argc > 7)
  {
    fprintf(stderr, "Usage: %s job-id user title copies options [file]\n", argv[0]);
    return 1;
  }
  if (argc == 7 && (fd = open(argv[6], O_RDONLY)) < 0)
  {
    logmsg("ERROR", "unable to open %s: %s", argv[6], strerror(errno));
    return 1;
  }

  input_fd = fd;
  struct sigaction sa;
  memset(&sa, 0, sizeof(sa));
  sa.sa_handler = on_term; /* no SA_RESTART: a waiting read returns at once */
  sigaction(SIGTERM, &sa, NULL);

  input_t        in  = {fd, 0, {0}, 0};
  cups_raster_t *ras = cupsRasterOpenIO(input_read, &in, CUPS_RASTER_READ);
  if (!ras)
  {
    logmsg("ERROR", "unable to read raster stream");
    return 1;
  }

  static char outbuf[OUTBUF_SIZE];
  out_t o;
  memset(&o, 0, sizeof(o));
  o.fp       = stdout;
  o.next_obj = 3;
  setvbuf(stdout, outbuf, _IOFBF, sizeof(outbuf));

  int    threads = detect_threads();
  pool_t pool;
  pool_init(&pool, threads);
  logmsg("DEBUG", "using %d thread(s)", pool.nthreads + 1);

#ifdef __APPLE__
  pthread_set_qos_class_self_np(QOS_CLASS_USER_INITIATED, 0);
#endif

  int  job_id = atoi(argv[1]);
  char start_time[64];
  job_start_time(start_time, sizeof(start_time));

  out_printf(&o, "%%PDF-1.7\n%%PCLm 1.0\n");

  cups_page_header2_t h;
  int                 page = 0, status = 0;
  unsigned long long  expected = 4; /* bytes of an uncompressed (v3) stream so far */
  strip_t             strips[MAX_THREADS * 2];
  int                 nbatch = (pool.nthreads + 1) * 2;
  size_t              alloc_w = 0;
  uint8_t            *line = NULL;
  size_t              line_cap = 0;
  memset(strips, 0, sizeof(strips));

  while (!canceled && cupsRasterReadHeader2(ras, &h))
  {
    page_t   pg;
    in_fmt_t fmt;
    int      invert;

    in_page = 1;
    page++;
    if (check_header(&h) || pick_format(&h, &fmt, &invert) || setup_page(&h, &pg))
    {
      page--;
      logmsg("ERROR", "unsupported raster: colorspace %d, %u bits/pixel, order %d",
             h.cupsColorSpace, h.cupsBitsPerPixel, h.cupsColorOrder);
      status = 1;
      break;
    }
    fprintf(stderr, "PAGE: %d 1\n", page);
    logmsg("DEBUG", "page %d: %ux%u px raster, media %dx%d pt, printable %dx%d px, margins top %d left %d, %d dpi",
           page, h.cupsWidth, h.cupsHeight, pg.media_w_pt, pg.media_h_pt, pg.src_w, pg.src_h,
           pg.top, pg.left, pg.res);

    /* (re)allocate strip buffers for this page width */
    size_t w = (size_t)pg.media_w_px;
    if (w > alloc_w)
    {
      for (int i = 0; i < nbatch; i++)
      {
        free(strips[i].gray);
        free(strips[i].rle);
        strips[i].gray = malloc(w * STRIP_H);
        strips[i].rle  = malloc(rle_bound(w * STRIP_H));
        if (!strips[i].gray || !strips[i].rle)
        {
          logmsg("ERROR", "out of memory");
          return 1;
        }
      }
      alloc_w = w;
    }
    if (h.cupsBytesPerLine > line_cap)
    {
      free(line);
      line_cap = h.cupsBytesPerLine;
      if (!(line = malloc(line_cap)))
      {
        logmsg("ERROR", "out of memory");
        return 1;
      }
    }

    expected += 1796ULL + (unsigned long long)h.cupsBytesPerLine * h.cupsHeight;
    write_ticket(&o, &pg, job_id, start_time);
    write_page_header(&o, &pg);

    /* white strips for the top margin */
    if (pg.top)
    {
      strip_t *s = &strips[0];
      memset(s->gray, 0xFF, w * STRIP_H);
      for (int i = 0; i < pg.top_full; i++)
      {
        s->lines = pg.top_full_lines;
        compress_strip(s, (int)w);
        write_strip(&o, (int)w, s->lines, s->rle, s->rle_len, 1);
      }
      if (pg.top_partial)
      {
        s->lines = pg.top_partial;
        compress_strip(s, (int)w);
        write_strip(&o, (int)w, s->lines, s->rle, s->rle_len, 1);
      }
    }

    /* image strips: read a batch serially, compress in parallel, write in order */
    unsigned row = 0; /* raster rows consumed */
    int      copy_w = pg.src_w < (int)h.cupsWidth ? pg.src_w : (int)h.cupsWidth;
    for (int sidx = 0; sidx < pg.nstrips; )
    {
      int n = 0;
      for (; n < nbatch && sidx + n < pg.nstrips; n++)
      {
        strip_t *s = &strips[n];
        int      y0 = (sidx + n) * STRIP_H;
        /* every strip carries STRIP_H lines; past the printable area it is white */
        s->lines = STRIP_H;
        memset(s->gray, 0xFF, w * STRIP_H);
        for (int l = 0; l < STRIP_H; l++)
        {
          if (y0 + l >= pg.src_h || row >= h.cupsHeight || canceled)
            break; /* the rest of the strip stays white */
          if (cupsRasterReadPixels(ras, line, h.cupsBytesPerLine) != h.cupsBytesPerLine)
          {
            if (!canceled)
            {
              logmsg("ERROR", "short raster data on page %d", page);
              status = 1;
            }
            row = h.cupsHeight;
            break;
          }
          row++;
          convert_line(line, s->gray + (size_t)l * w + pg.left, copy_w, fmt, invert);
        }
      }
      pool_run(&pool, strips, n, (int)w);
      for (int i = 0; i < n; i++)
        write_strip(&o, (int)w, strips[i].lines, strips[i].rle, strips[i].rle_len, strips[i].white);
      sidx += n;
    }
    /* skip raster rows below the printable area */
    while (row < h.cupsHeight && !canceled)
    {
      if (cupsRasterReadPixels(ras, line, h.cupsBytesPerLine) != h.cupsBytesPerLine)
        break;
      row++;
    }
    if (o.error)
    {
      logmsg("ERROR", "write error: %s", strerror(errno));
      status = 1;
      break;
    }
    if (status || canceled)
      break;
    in_page = 0;
  }
  in_page = 1; /* from here on, finish the file even if SIGTERM arrives */

  /* Uncompressed raster ("RaS3"/"3SaR"): any bytes beyond the last full page mean a
   * page header was cut off or corrupt. Compressed streams can't be measured this way. */
  if (!status && !canceled && in.nsync == 4 &&
      (!memcmp(in.sync, "RaS3", 4) || !memcmp(in.sync, "3SaR", 4)))
  {
    unsigned char extra;
    unsigned long long total = in.total + (unsigned long long)(read(fd, &extra, 1) > 0);
    if (total > expected)
    {
      logmsg("ERROR", "raster data ends inside page %d's header (corrupt or cut-off job)", page + 1);
      status = 1;
    }
  }

  if (page == 0 && !status)
  {
    logmsg("ERROR", "no valid pages in the job (empty or corrupt raster data)");
    status = 1;
  }
  if (canceled)
  {
    logmsg("INFO", "job canceled after page %d", page);
    status = 1;
  }

  write_trailer(&o);
  fflush(stdout);
  if (o.error || ferror(stdout))
    status = 1;

  pool_destroy(&pool);
  for (int i = 0; i < nbatch; i++)
  {
    free(strips[i].gray);
    free(strips[i].rle);
  }
  free(line);
  free(o.xref);
  free(o.kids);
  cupsRasterClose(ras);
  if (fd)
    close(fd);
  logmsg("INFO", "%d page(s) done", page);
  return status;
}
