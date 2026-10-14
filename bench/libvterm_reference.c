/* Optional development oracle/benchmark. No native code is used at runtime. */
#define _POSIX_C_SOURCE 200809L
#include <vterm.h>
#include <stdio.h>
#include <stdlib.h>
#include <stdint.h>
#include <string.h>
#include <time.h>

#if VTERM_VERSION_MAJOR != 0 || VTERM_VERSION_MINOR != 3 || VTERM_VERSION_PATCH != 3
#error "This comparison targets the libvterm 0.3.3 release"
#endif

static double now_ns(void) {
  struct timespec t;
  if (clock_gettime(CLOCK_MONOTONIC, &t)) exit(2);
  return (double)t.tv_sec * 1e9 + t.tv_nsec;
}

static VTerm *terminal(int rows, int cols) {
  VTerm *vt = vterm_new(rows, cols);
  vterm_set_utf8(vt, 1);
  VTermScreen *screen = vterm_obtain_screen(vt);
  vterm_screen_enable_altscreen(screen, 1);
  vterm_screen_reset(screen, 1);
  return vt;
}

static void feed(VTerm *vt, const char *bytes, size_t len, size_t chunk) {
  for (size_t p = 0; p < len; p += chunk) {
    size_t n = len - p < chunk ? len - p : chunk;
    vterm_input_write(vt, bytes + p, n);
  }
}

static void color(VTermColor *c, int foreground) {
  if ((foreground && VTERM_COLOR_IS_DEFAULT_FG(c)) ||
      (!foreground && VTERM_COLOR_IS_DEFAULT_BG(c))) printf("d");
  else if (VTERM_COLOR_IS_INDEXED(c)) printf("i:%u", c->indexed.idx);
  else printf("r:%u,%u,%u", c->rgb.red, c->rgb.green, c->rgb.blue);
}

int main(int argc, char **argv) {
  if (argc != 8) {
    fprintf(stderr, "usage: reference snapshot|snapshot-attrs|bench COLS ROWS INPUT ITERATIONS CHUNK SAMPLES\n");
    return 2;
  }
  int cols = atoi(argv[2]), rows = atoi(argv[3]);
  int iterations = atoi(argv[5]), samples = atoi(argv[7]);
  size_t chunk = (size_t)strtoul(argv[6], NULL, 10);
  if (cols < 1 || rows < 1 || iterations < 1 || samples < 1) return 2;
  FILE *f = fopen(argv[4], "rb");
  if (!f || fseek(f, 0, SEEK_END)) return 2;
  long length = ftell(f);
  if (length < 0 || fseek(f, 0, SEEK_SET)) return 2;
  size_t len = (size_t)length;
  char *bytes = malloc(len + 1);
  if (!bytes || fread(bytes, 1, len, f) != len) return 2;
  fclose(f);
  if (!chunk) chunk = len ? len : 1;

  if (!strcmp(argv[1], "bench")) {
    for (int s = 0; s < samples; s++) {
      VTerm *vt = terminal(rows, cols);
      double start = now_ns();
      for (int i = 0; i < iterations; i++) feed(vt, bytes, len, chunk);
      double elapsed = now_ns() - start;
      /* Read state after timing so the benchmark result remains observable. */
      VTermPos pos;
      vterm_state_get_cursorpos(vterm_obtain_state(vt), &pos);
      printf("%.3f\t%d\t%d\n", elapsed / iterations / 1000.0, pos.row, pos.col);
      vterm_free(vt);
    }
  } else if (!strcmp(argv[1], "snapshot") || !strcmp(argv[1], "snapshot-attrs")) {
    VTerm *vt = terminal(rows, cols);
    for (int i = 0; i < iterations; i++) feed(vt, bytes, len, chunk);
    VTermPos pos;
    vterm_state_get_cursorpos(vterm_obtain_state(vt), &pos);
    printf("%d\t%d\n", pos.row, pos.col);
    VTermScreen *screen = vterm_obtain_screen(vt);
    for (int row = 0; row < rows; row++) {
      for (int col = 0; col < cols; col++) {
        VTermScreenCell cell;
        vterm_screen_get_cell(screen, (VTermPos){row, col}, &cell);
        if (cell.chars[0] == UINT32_MAX) printf("-");
        else if (!cell.chars[0]) printf("32");
        else {
          for (int c = 0; c < VTERM_MAX_CHARS_PER_CELL && cell.chars[c]; c++)
            printf("%s%u", c ? "," : "", cell.chars[c]);
        }
        printf("\t%u\t%u\t%u\t", cell.attrs.bold, cell.attrs.italic, cell.attrs.reverse);
        color(&cell.fg, 1); printf("\t"); color(&cell.bg, 0);
        if (!strcmp(argv[1], "snapshot-attrs"))
          printf("\t%u\t%u\t%u\t%u\t%u", cell.attrs.underline,
                 cell.attrs.blink, cell.attrs.conceal, cell.attrs.strike, cell.attrs.font);
        printf("\n");
      }
    }
    vterm_free(vt);
  } else return 2;
  free(bytes);
  return 0;
}
