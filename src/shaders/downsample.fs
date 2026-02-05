#version 330

in vec2 fragTexCoord;
in vec4 fragColor;

uniform sampler2D texture0;
uniform vec2 sourceSize;  // Original texture dimensions
uniform vec2 destSize;    // Rendered thumbnail dimensions

out vec4 finalColor;

void main() {
    // Calculate downscale ratio
    vec2 scale = sourceSize / destSize;

    // Number of samples per axis (clamped to 2-8 range)
    int samplesX = clamp(int(ceil(scale.x)), 2, 8);
    int samplesY = clamp(int(ceil(scale.y)), 2, 8);

    vec2 texelSize = 1.0 / sourceSize;
    vec4 color = vec4(0.0);
    float totalSamples = float(samplesX * samplesY);

    // Calculate the area we need to sample (in texels)
    vec2 sampleArea = scale * texelSize;

    // Sample a grid centered on the current texel
    for (int y = 0; y < samplesY; y++) {
        for (int x = 0; x < samplesX; x++) {
            // Offset within the sample area
            vec2 offset = vec2(
                (float(x) + 0.5) / float(samplesX) - 0.5,
                (float(y) + 0.5) / float(samplesY) - 0.5
            ) * sampleArea;

            color += texture(texture0, fragTexCoord + offset);
        }
    }

    finalColor = (color / totalSamples) * fragColor;
}
