/* input-probe: Peel never loses key or button changes (tools/input_smoke.py).
 *
 * Opens a large window and does not read its input for three seconds, so
 * its port (16 messages) fills while the test floods pointer motion over it
 * and presses Ctrl+T. Then it drains everything and reports the Ctrl and T
 * presses and releases it saw: every press must have its release, or a
 * program would believe Ctrl is still held (Orange Browser then took typed
 * letters as tab shortcuts).
 *
 * SPDX-License-Identifier: MIT OR Apache-2.0
 */
#include <stdint.h>
#include <stdio.h>
#include <unistd.h>

typedef struct {
	int32_t width, height, scale, stride;
	uint32_t *pixels;
} PeelInfo;
typedef struct {
	uint32_t kind, code, value;
	int32_t x, y;
} PeelEvent;
int orange_peel_open(const char *title, int width, int height, PeelInfo *info);
void orange_peel_commit(int x, int y, int width, int height);
int orange_peel_next_event(PeelEvent *event, int blocking);

int main(void)
{
	/* After the desktop's own windows, so this one is the newest and has
	 * the keyboard. */
	sleep(20);
	PeelInfo info;
	if (orange_peel_open("Input probe", 900, 560, &info) != 0) {
		printf("input-probe: FAIL no window\n");
		return 1;
	}
	for (int i = 0; i < info.stride * info.height * info.scale; i++)
		info.pixels[i] = 0x336699;
	orange_peel_commit(0, 0, info.width, info.height);
	printf("input-probe: ready\n");
	fflush(stdout);
	sleep(3);
	int ctrl_down = 0, ctrl_up = 0, t_down = 0, t_up = 0, motion = 0;
	for (int idle = 0; idle < 200;) {
		PeelEvent e;
		int r = orange_peel_next_event(&e, 0);
		if (r < 0)
			break;
		if (r == 0) {
			idle++;
			usleep(10000);
			continue;
		}
		idle = 0;
		if (e.kind == 2)
			motion++;
		if (e.kind != 1)
			continue;
		int pressed = e.value & 1;
		if (e.code == 0x1D)
			pressed ? ctrl_down++ : ctrl_up++;
		if (e.code == 0x14)
			pressed ? t_down++ : t_up++;
	}
	int ok = ctrl_down >= 1 && ctrl_down == ctrl_up && t_down >= 1 && t_down == t_up;
	printf("input-probe: %s ctrl %d down %d up, t %d down %d up, %d pointer events\n", ok ? "PASS" : "FAIL", ctrl_down,
	       ctrl_up, t_down, t_up, motion);
	return ok ? 0 : 1;
}
