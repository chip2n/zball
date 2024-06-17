#include <stdlib.h>
#include <stdio.h>
#include <stdbool.h>
#include "janet.h"

#define BOOTSCRIPT "./boot.janet"
static char bootBuffer[128] = {0};

static Janet c_begin_draw(int32_t argc, Janet *argv) {
  janet_fixarity(argc, 0);
  /* BeginDrawing(); */
  /* ClearBackground(BLACK); */
  return janet_wrap_nil();
}

static Janet c_end_draw(int32_t argc, Janet *argv) {
  janet_fixarity(argc, 0);
  /* EndDrawing(); */
  return janet_wrap_nil();
}

bool load_script(char *buffer, const char *path) {
  FILE *bootFile = fopen(path, "r");
  if (NULL == bootFile) {
    fprintf(stderr, "failed to open boot script!");
    return false;
  }

  fseek(bootFile, 0, SEEK_END);
  size_t size = ftell(bootFile);
  rewind(bootFile);
  if(0 >= size) {
    fprintf(stderr, "boot script is empty or broken!");
    return false;
  }

  fread(buffer, sizeof(char), size, bootFile);

  return true;
}

int main(int argc, char **argv) {
    if (0 != janet_init()) {
        fprintf(stderr, "failed to bring up lisp machine!");
        return EXIT_FAILURE;
    }

    JanetTable *jenv = janet_core_env(NULL);
    if (NULL == jenv) {
        fprintf(stderr, "failed to set up lisp machine!");
        return EXIT_FAILURE;
    }

    JanetReg cfuns[] = {
        {"c/begin-draw", c_begin_draw, ""},
        {"c/end-draw", c_end_draw, ""},
        {NULL, NULL, NULL}
    };
    janet_cfuns(jenv, "c", cfuns);

    if (!load_script(bootBuffer, BOOTSCRIPT)) {
        return EXIT_SUCCESS;
    }

    Janet res;
    janet_dostring(jenv, bootBuffer, NULL, &res);
    janet_deinit();
    return EXIT_SUCCESS;
}
